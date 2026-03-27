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
  # Use specified version or latest available
  kubernetes_version = coalesce(
    var.kubernetes_version,
    reverse(sort(data.oci_containerengine_cluster_option.this.kubernetes_versions))[0]
  )

  # Find the latest OKE-optimized ARM image matching the cluster k8s version
  # OKE-optimized images have pre-installed k8s packages (name contains "OKE-<version>")
  # Extract major.minor from k8s version (e.g. "v1.35.0" → "1.35")
  k8s_major_minor = join(".", slice(split(".", trimprefix(local.kubernetes_version, "v")), 0, 2))

  oke_arm_images = [
    for source in data.oci_containerengine_node_pool_option.this.sources :
    source if length(regexall("aarch64", source.source_name)) > 0 && length(regexall("OKE-${local.k8s_major_minor}", source.source_name)) > 0
  ]

  latest_arm_image_id = local.oke_arm_images[0].image_id

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
      condition     = length(local.oke_arm_images) > 0
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
