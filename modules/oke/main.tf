# Fetch available Kubernetes versions
data "oci_containerengine_cluster_option" "this" {
  cluster_option_id = "all"
}

# Fetch availability domains
data "oci_identity_availability_domains" "this" {
  compartment_id = var.compartment_ocid
}

# Fetch ARM (aarch64) node images
data "oci_containerengine_node_pool_option" "this" {
  node_pool_option_id = "all"
  compartment_id      = var.compartment_ocid
}

locals {
  # Use specified version or latest available.
  # Lexicographic sort is safe here because OCI K8s versions always use 2-digit
  # minor numbers (e.g. "v1.28.2", "v1.31.1"), so string ordering equals semver.
  kubernetes_version = coalesce(
    var.kubernetes_version,
    reverse(sort(data.oci_containerengine_cluster_option.this.kubernetes_versions))[0]
  )

  # Find the latest OKE-optimized ARM image matching the cluster k8s version.
  # Image names contain a date (e.g. "Oracle-Linux-8.10-aarch64-2026.02.28-0-OKE-1.35.0-1392"),
  # so lexicographic sort on source_name selects the most recent patch.
  k8s_major_minor = join(".", slice(split(".", trimprefix(local.kubernetes_version, "v")), 0, 2))

  oke_arm_image_map = {
    for source in data.oci_containerengine_node_pool_option.this.sources :
    source.source_name => source.image_id
    if length(regexall("aarch64", source.source_name)) > 0 && length(regexall("OKE-${local.k8s_major_minor}", source.source_name)) > 0
  }

  latest_arm_image_id = local.oke_arm_image_map[reverse(sort(keys(local.oke_arm_image_map)))[0]]

  # All availability domains
  availability_domains = data.oci_identity_availability_domains.this.availability_domains
}

# ──────────────────────────────────────────────────────────────────────────────
# OKE Cluster (Basic - Always Free)
# ──────────────────────────────────────────────────────────────────────────────

# Gate: cluster creation waits for Always Free limit validation,
# but data sources above can start immediately in parallel.
resource "terraform_data" "always_free_gate" {
  input = var.always_free_validation_id
}

resource "terraform_data" "image_validation" {
  lifecycle {
    precondition {
      condition     = length(local.oke_arm_image_map) > 0
      error_message = "No OKE-optimized ARM (aarch64) image found for Kubernetes ${local.kubernetes_version}. Check that the version is available in your region."
    }
  }
}

resource "oci_containerengine_cluster" "this" {
  compartment_id     = var.compartment_ocid
  kubernetes_version = local.kubernetes_version
  name               = var.cluster_name
  vcn_id             = var.vcn_id

  # HARDCODED: Basic cluster is free. Enhanced cluster incurs charges.
  type = "BASIC_CLUSTER"

  cluster_pod_network_options {
    cni_type = "FLANNEL_OVERLAY"
  }

  endpoint_config {
    is_public_ip_enabled = true
    subnet_id            = var.api_endpoint_subnet_id
  }

  options {
    service_lb_subnet_ids = [var.lb_subnet_id]
  }

  freeform_tags = var.freeform_tags

  depends_on = [terraform_data.always_free_gate]
}

# ──────────────────────────────────────────────────────────────────────────────
# Node Pool (ARM A1.Flex - Always Free)
# ──────────────────────────────────────────────────────────────────────────────

resource "oci_containerengine_node_pool" "this" {
  compartment_id     = var.compartment_ocid
  cluster_id         = oci_containerengine_cluster.this.id
  kubernetes_version = local.kubernetes_version
  name               = "${var.cluster_name}-node-pool"

  # HARDCODED: VM.Standard.A1.Flex is Always Free (up to 4 OCPUs, 24 GB RAM)
  node_shape = "VM.Standard.A1.Flex"

  node_shape_config {
    ocpus         = var.node_ocpus
    memory_in_gbs = var.node_memory_in_gbs
  }

  node_source_details {
    source_type             = "IMAGE"
    image_id                = local.latest_arm_image_id
    boot_volume_size_in_gbs = var.boot_volume_size_in_gbs
  }

  # Cloud-init: expand root LV to fill the full boot volume before OKE bootstrap.
  # The OKE platform image allocates only ~45 GB of raw disk to the LVM PV (sda3),
  # leaving unallocated space even on a 64 GB volume. oci-growfs extends the
  # partition, resizes the PV, extends ocivolume-root, and grows the XFS filesystem
  # online — all before kubelet starts pulling images into /var/lib/containerd.
  # Reference: Oracle Cloud Infrastructure docs, "Using Custom Cloud-init Scripts",
  # Example 5 (https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengusingcustomcloudinitscripts.htm)
  #
  # NOTE: Changing node_metadata on an existing node pool does not replace running
  # nodes. New nodes created after apply (or after manual node cycling) will pick
  # up the expanded disk automatically.
  node_metadata = var.node_disk_expansion_enabled ? {
    user_data = base64encode(<<-EOT
      #!/bin/bash
      curl --fail -H "Authorization: Bearer Oracle" -L0 \
        http://169.254.169.254/opc/v2/instance/metadata/oke_init_script \
        | base64 --decode > /var/run/oke-init.sh
      bash /usr/libexec/oci-growfs -y
      bash /var/run/oke-init.sh
    EOT
    )
  } : {}

  node_config_details {
    size = var.node_count

    dynamic "placement_configs" {
      for_each = local.availability_domains
      content {
        availability_domain = placement_configs.value.name
        subnet_id           = var.worker_subnet_id
      }
    }
  }

  ssh_public_key = var.ssh_public_key

  freeform_tags = var.freeform_tags

  depends_on = [terraform_data.image_validation]
}
