provider "oci" {
  tenancy_ocid        = var.tenancy_ocid
  user_ocid           = var.user_ocid
  fingerprint         = var.fingerprint
  private_key_path    = var.private_key_path
  region              = var.region
  config_file_profile = var.config_file_profile
}

locals {
  # Always Free resource limit validations
  total_ocpus               = var.node_count * var.node_ocpus
  total_memory_in_gbs       = var.node_count * var.node_memory_in_gbs
  total_boot_volume_in_gbs  = var.node_count * var.boot_volume_size_in_gbs
  total_block_volume_in_gbs = local.total_boot_volume_in_gbs + (var.enable_nfs_storage ? var.nfs_volume_size_in_gbs : 0)
}

# Always Free safety checks
resource "terraform_data" "always_free_validation" {
  lifecycle {
    precondition {
      condition     = local.total_ocpus <= 4
      error_message = "Total OCPUs (${local.total_ocpus}) exceeds Always Free limit of 4. Reduce node_count or node_ocpus."
    }
    precondition {
      condition     = local.total_memory_in_gbs <= 24
      error_message = "Total memory (${local.total_memory_in_gbs} GB) exceeds Always Free limit of 24 GB. Reduce node_count or node_memory_in_gbs."
    }
    precondition {
      condition     = local.total_block_volume_in_gbs <= 200
      error_message = "Total block volume (${local.total_block_volume_in_gbs} GB: ${local.total_boot_volume_in_gbs} GB boot + ${var.enable_nfs_storage ? var.nfs_volume_size_in_gbs : 0} GB NFS) exceeds Always Free limit of 200 GB."
    }
    precondition {
      condition     = !var.enable_budget_alert || var.notification_email != null
      error_message = "notification_email is required when enable_budget_alert is true."
    }
  }
}

module "network" {
  source = "./modules/network"

  compartment_ocid   = var.compartment_ocid
  vcn_cidr           = var.vcn_cidr
  enable_nat_gateway = var.enable_nat_gateway
  freeform_tags      = var.freeform_tags
}

module "oke" {
  source = "./modules/oke"

  compartment_ocid          = var.compartment_ocid
  cluster_name              = var.cluster_name
  kubernetes_version        = var.kubernetes_version
  vcn_id                    = module.network.vcn_id
  api_endpoint_subnet_id    = module.network.api_endpoint_subnet_id
  worker_subnet_id          = module.network.worker_subnet_id
  lb_subnet_id              = module.network.lb_subnet_id
  node_count                = var.node_count
  node_ocpus                = var.node_ocpus
  node_memory_in_gbs        = var.node_memory_in_gbs
  boot_volume_size_in_gbs   = var.boot_volume_size_in_gbs
  ssh_public_key            = var.ssh_public_key
  freeform_tags             = var.freeform_tags
  always_free_validation_id = terraform_data.always_free_validation.id
}

# ──────────────────────────────────────────────────────────────────────────────
# Cluster Add-ons (Helm)
# ──────────────────────────────────────────────────────────────────────────────

data "oci_containerengine_cluster_kube_config" "this" {
  cluster_id    = module.oke.cluster_id
  token_version = "2.0.0"
  endpoint      = "PUBLIC_ENDPOINT"
}

locals {
  kubeconfig             = yamldecode(data.oci_containerengine_cluster_kube_config.this.content)
  cluster_ca_certificate = base64decode(local.kubeconfig.clusters[0].cluster["certificate-authority-data"])
}

provider "helm" {
  kubernetes = {
    host                   = module.oke.cluster_endpoint
    cluster_ca_certificate = local.cluster_ca_certificate
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "oci"
      args        = ["ce", "cluster", "generate-token", "--cluster-id", module.oke.cluster_id, "--region", split(".", module.oke.cluster_id)[3]]
    }
  }
}

resource "helm_release" "metrics_server" {
  count = var.enable_metrics_server ? 1 : 0

  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = "kube-system"

  depends_on = [module.oke]
}

# ──────────────────────────────────────────────────────────────────────────────
# NFS Storage (dynamic PV provisioning)
# ──────────────────────────────────────────────────────────────────────────────

resource "helm_release" "nfs_server_provisioner" {
  count = var.enable_nfs_storage ? 1 : 0

  name             = "nfs-server-provisioner"
  repository       = "https://kubernetes-sigs.github.io/nfs-ganesha-server-and-external-provisioner/"
  chart            = "nfs-server-provisioner"
  version          = "1.8.0"
  namespace        = "nfs-storage"
  create_namespace = true

  values = [yamlencode({
    persistence = {
      enabled      = true
      storageClass = "oci-bv"
      size         = "${var.nfs_volume_size_in_gbs}Gi"
    }
    storageClass = {
      name         = "nfs"
      defaultClass = false
    }
  })]

  depends_on = [module.oke]
}

# ──────────────────────────────────────────────────────────────────────────────
# Budget
# ──────────────────────────────────────────────────────────────────────────────

module "budget" {
  source = "./modules/budget"
  count  = var.enable_budget_alert ? 1 : 0

  compartment_ocid   = var.compartment_ocid
  notification_email = var.notification_email
  freeform_tags      = var.freeform_tags

  depends_on = [terraform_data.always_free_validation]
}
