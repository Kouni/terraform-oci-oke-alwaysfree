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
    precondition {
      condition = (
        (var.config_file_profile != null && var.tenancy_ocid == null && var.user_ocid == null && var.fingerprint == null && var.private_key_path == null) ||
        (var.config_file_profile == null && var.tenancy_ocid != null && var.user_ocid != null && var.fingerprint != null && var.private_key_path != null && var.region != null)
      )
      error_message = "Specify either config_file_profile (recommended) OR all of tenancy_ocid, user_ocid, fingerprint, private_key_path, and region — not both."
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
  cluster_ca_certificate = base64decode(try(local.kubeconfig.clusters[0].cluster["certificate-authority-data"], ""))
}

provider "helm" {
  kubernetes = {
    host                   = module.oke.cluster_endpoint
    cluster_ca_certificate = local.cluster_ca_certificate
    exec = {
      # OCI CLI currently returns v1beta1 ExecCredential regardless of requested version.
      # Track: https://github.com/oracle/oci-cli/issues — update to v1 once OCI CLI supports it.
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
    # OCI CLI currently returns v1beta1 ExecCredential regardless of requested version.
    # Track: https://github.com/oracle/oci-cli/issues — update to v1 once OCI CLI supports it.
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

# XFS-backed StorageClass for the NFS server's backing PVC.
# XFS project quotas (--enable-xfs-quota) enforce per-PVC storage limits so pods
# cannot write beyond their requests.storage.
resource "kubernetes_storage_class_v1" "oci_bv_xfs" {
  count = var.enable_nfs_storage ? 1 : 0

  metadata {
    name = "oci-bv-xfs"
  }

  storage_provisioner    = "blockvolume.csi.oraclecloud.com"
  reclaim_policy         = "Delete"
  allow_volume_expansion = true
  volume_binding_mode    = "WaitForFirstConsumer"
  mount_options          = ["pquota"]

  parameters = {
    "csi.storage.k8s.io/fstype" = "xfs"
  }

  depends_on = [module.oke]
}

resource "helm_release" "nfs_server_provisioner" {
  count = var.enable_nfs_storage ? 1 : 0

  name             = "nfs-server-provisioner"
  repository       = null
  chart            = "${path.module}/charts"
  namespace        = "nfs-storage"
  create_namespace = true

  values = [yamlencode({
    persistence = {
      enabled      = true
      storageClass = "oci-bv-xfs"
      size         = "${var.nfs_volume_size_in_gbs}Gi"
    }
    storageClass = {
      name         = "nfs"
      defaultClass = false
    }
    extraArgs = {
      "enable-xfs-quota" = true
    }
    securityContext = {
      capabilities = {
        add = ["DAC_READ_SEARCH", "SYS_RESOURCE", "SYS_ADMIN"]
      }
    }
    # Mount host /dev so xfs_quota can open the backing block device
    # (discovered dynamically from /proc/mounts) for quota ioctls.
    extraVolumes = [
      {
        name     = "host-dev"
        hostPath = { path = "/dev", type = "Directory" }
      }
    ]
    extraVolumeMounts = [
      {
        name      = "host-dev"
        mountPath = "/dev"
      }
    ]
  })]

  depends_on = [module.oke, kubernetes_storage_class_v1.oci_bv_xfs]
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
# Kubernetes Namespaces
# These are intentionally NOT gated on enable_n8n / enable_cloudflare_tunnel so
# that disabling a feature never cascades into deleting the namespace (and with
# it the PVC / persistent data inside).
# ──────────────────────────────────────────────────────────────────────────────

moved {
  from = kubernetes_namespace_v1.n8n[0]
  to   = kubernetes_namespace_v1.n8n
}

moved {
  from = kubernetes_namespace_v1.tunnel[0]
  to   = kubernetes_namespace_v1.tunnel
}

resource "kubernetes_namespace_v1" "n8n" {
  metadata {
    name = var.n8n_namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  depends_on = [module.oke]
}

resource "kubernetes_namespace_v1" "tunnel" {
  metadata {
    name = var.cloudflare_tunnel_namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  depends_on = [module.oke]
}

# ──────────────────────────────────────────────────────────────────────────────
# Persistent Volume Claims
# These are intentionally NOT gated on enable_n8n so that disabling the feature
# never destroys stored data. The PVC outlives the Helm release; when n8n is
# re-enabled it mounts the same claim and all workflows/credentials are intact.
# ──────────────────────────────────────────────────────────────────────────────

resource "kubernetes_persistent_volume_claim_v1" "n8n_data" {
  count = var.enable_nfs_storage ? 1 : 0
  metadata {
    name      = "n8n-data"
    namespace = kubernetes_namespace_v1.n8n.metadata[0].name
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "nfs"
    resources {
      requests = {
        storage = var.n8n_pvc_size
      }
    }
  }

  lifecycle {
    # Prevent accidental data loss — must be manually removed from state before destroy
    prevent_destroy = true
    # PVC spec is immutable after binding; ignore any drift
    ignore_changes = [spec]
  }

  depends_on = [module.oke, helm_release.nfs_server_provisioner, kubernetes_namespace_v1.n8n]
}

# ──────────────────────────────────────────────────────────────────────────────
# Kubernetes Secrets
# ──────────────────────────────────────────────────────────────────────────────

resource "kubernetes_secret_v1" "n8n_secrets" {
  count = var.enable_n8n ? 1 : 0

  metadata {
    name      = var.n8n_secret_name
    namespace = kubernetes_namespace_v1.n8n.metadata[0].name
  }

  data = {
    N8N_ENCRYPTION_KEY = var.n8n_encryption_key
    N8N_HOST           = var.n8n_host
    N8N_PORT           = "5678"
    N8N_PROTOCOL       = "https"
  }

  lifecycle {
    precondition {
      condition     = var.n8n_encryption_key != null
      error_message = "n8n_encryption_key is required when enable_n8n is true. For existing clusters, extract the current key with: kubectl get secret n8n-secrets -n n8n -o jsonpath='{.data.N8N_ENCRYPTION_KEY}' | base64 -d"
    }
    precondition {
      condition     = var.n8n_host != null
      error_message = "n8n_host is required when enable_n8n is true (e.g. n8n.example.com)."
    }
  }
}

resource "kubernetes_secret_v1" "cloudflare_tunnel" {
  count = var.enable_cloudflare_tunnel ? 1 : 0

  metadata {
    name      = var.cloudflared_secret_name
    namespace = kubernetes_namespace_v1.tunnel.metadata[0].name
  }

  data = {
    TUNNEL_TOKEN = var.cloudflare_tunnel_token
  }

  lifecycle {
    precondition {
      condition     = var.cloudflare_tunnel_token != null
      error_message = "cloudflare_tunnel_token is required when enable_cloudflare_tunnel is true."
    }
  }
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
  create_namespace = false

  values = [yamlencode({
    image = {
      repository = "docker.n8n.io/n8nio/n8n"
      tag        = var.n8n_image_tag
      pullPolicy = var.n8n_image_tag == "latest" ? "Always" : "IfNotPresent"
    }

    # Standalone mode: SQLite, no external PostgreSQL/Redis
    queueMode = { enabled = false }
    database  = { type = "sqlite", useExternal = false }
    redis     = { enabled = false }

    # Persistent storage — uses Terraform-managed PVC so data survives helm uninstall
    persistence = {
      enabled       = true
      existingClaim = kubernetes_persistent_volume_claim_v1.n8n_data[0].metadata[0].name
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

  depends_on = [module.oke, helm_release.nfs_server_provisioner, kubernetes_namespace_v1.n8n, kubernetes_secret_v1.n8n_secrets, kubernetes_persistent_volume_claim_v1.n8n_data]

  lifecycle {
    precondition {
      condition     = var.enable_nfs_storage
      error_message = "enable_nfs_storage must be true when enable_n8n is true (n8n requires the NFS StorageClass)."
    }
    precondition {
      condition     = var.enable_cloudflare_tunnel
      error_message = "enable_cloudflare_tunnel must be true when enable_n8n is true (n8n requires Cloudflare Tunnel for ingress)."
    }
  }
}


# ──────────────────────────────────────────────────────────────────────────────
# Cloudflare Tunnel
# ──────────────────────────────────────────────────────────────────────────────

resource "kubernetes_deployment_v1" "cloudflared" {
  count = var.enable_cloudflare_tunnel ? 1 : 0

  metadata {
    name      = "cloudflared"
    namespace = var.cloudflare_tunnel_namespace
    labels = {
      "app.kubernetes.io/name"      = "cloudflared"
      "app.kubernetes.io/component" = "tunnel"
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
        }
      }

      spec {
        container {
          name  = "cloudflared"
          image = "docker.io/cloudflare/cloudflared:${var.cloudflared_image_tag}"
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

  depends_on = [terraform_data.always_free_validation, kubernetes_namespace_v1.tunnel, kubernetes_secret_v1.cloudflare_tunnel]
}
