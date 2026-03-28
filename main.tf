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

provider "kubernetes" {
  host                   = module.oke.cluster_endpoint
  cluster_ca_certificate = local.cluster_ca_certificate
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "oci"
    args        = ["ce", "cluster", "generate-token", "--cluster-id", module.oke.cluster_id, "--region", split(".", module.oke.cluster_id)[3]]
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

# ──────────────────────────────────────────────────────────────────────────────
# n8n (workflow automation, Cloudflare Zero Trust Tunnel)
# ──────────────────────────────────────────────────────────────────────────────

resource "helm_release" "n8n" {
  count = var.enable_n8n ? 1 : 0

  name             = "n8n"
  repository       = "oci://ghcr.io/n8n-io/n8n-helm-chart"
  chart            = "n8n"
  version          = var.n8n_chart_version
  namespace        = var.n8n_namespace
  create_namespace = true

  values = [yamlencode({
    image = {
      repository = "docker.n8n.io/n8nio/n8n"
      tag        = "latest"
      pullPolicy = "Always"
    }

    # Standalone mode: SQLite, no external PostgreSQL/Redis
    queueMode = { enabled = false }
    database  = { type = "sqlite", useExternal = false }
    redis     = { enabled = false }

    # Persistent storage (NFS)
    persistence = {
      enabled          = true
      storageClassName = "nfs"
      size             = var.n8n_pvc_size
      accessModes      = ["ReadWriteOnce"]
    }

    # Use pre-created K8s Secret for n8n core settings
    secretRefs = {
      existingSecret = var.n8n_secret_name
    }

    # ClusterIP only — no OCI Load Balancer
    service = {
      type = "ClusterIP"
      port = 5678
    }

    # Ingress disabled — Cloudflare Tunnel handles external access
    ingress = { enabled = false }

    # Resources (ARM A1.Flex, leave room for other workloads)
    resources = {
      main = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { cpu = "500m", memory = "512Mi" }
      }
    }

    # Security context (n8n UID 1000, fsGroup handles NFS permissions)
    securityContext = {
      enabled    = true
      fsGroup    = 1000
      runAsUser  = 1000
      runAsGroup = 1000
    }

    # Single replica — disable PDB
    pdb = { enabled = false }
  })]

  depends_on = [module.oke, helm_release.nfs_server_provisioner]

  lifecycle {
    precondition {
      condition     = var.enable_nfs_storage
      error_message = "enable_nfs_storage must be true when enable_n8n is true (n8n requires the NFS StorageClass)."
    }
  }
}

resource "kubernetes_deployment_v1" "cloudflared" {
  count = var.enable_n8n ? 1 : 0

  metadata {
    name      = "cloudflared"
    namespace = var.n8n_namespace
    labels = {
      "app.kubernetes.io/name"      = "cloudflared"
      "app.kubernetes.io/component" = "tunnel"
      "app.kubernetes.io/part-of"   = "n8n"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        "app.kubernetes.io/name" = "cloudflared"
      }
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"      = "cloudflared"
          "app.kubernetes.io/component" = "tunnel"
          "app.kubernetes.io/part-of"   = "n8n"
        }
      }

      spec {
        container {
          name  = "cloudflared"
          image = "docker.io/cloudflare/cloudflared:latest"
          args  = ["tunnel", "--no-autoupdate", "run"]

          env {
            name = "TUNNEL_TOKEN"
            value_from {
              secret_key_ref {
                name = var.cloudflared_secret_name
                key  = "TUNNEL_TOKEN"
              }
            }
          }

          resources {
            requests = {
              cpu    = "10m"
              memory = "32Mi"
            }
            limits = {
              cpu    = "100m"
              memory = "128Mi"
            }
          }

          security_context {
            allow_privilege_escalation = false
            run_as_non_root            = true
            run_as_user                = 65532
            capabilities {
              drop = ["ALL"]
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.n8n]
}
