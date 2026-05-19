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

  tailscale_hostname = coalesce(var.tailscale_hostname, var.cluster_name)
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
        (var.config_file_profile != null && var.tenancy_ocid == null && var.user_ocid == null && var.fingerprint == null && var.private_key_path == null && var.region == null) ||
        (var.config_file_profile == null && var.tenancy_ocid != null && var.user_ocid != null && var.fingerprint != null && var.private_key_path != null && var.region != null)
      )
      error_message = "Specify either config_file_profile (recommended) OR all of tenancy_ocid, user_ocid, fingerprint, private_key_path, and region — not both."
    }
  }
}

module "network" {
  source = "./modules/network"

  compartment_ocid       = var.compartment_ocid
  freeform_tags          = var.freeform_tags
  kube_api_allowed_cidrs = var.kube_api_allowed_cidrs
}

module "oke" {
  source = "./modules/oke"

  compartment_ocid            = var.compartment_ocid
  cluster_name                = var.cluster_name
  kubernetes_version          = var.kubernetes_version
  vcn_id                      = module.network.vcn_id
  api_endpoint_subnet_id      = module.network.api_endpoint_subnet_id
  worker_subnet_id            = module.network.worker_subnet_id
  lb_subnet_id                = module.network.lb_subnet_id
  node_count                  = var.node_count
  node_ocpus                  = var.node_ocpus
  node_memory_in_gbs          = var.node_memory_in_gbs
  boot_volume_size_in_gbs     = var.boot_volume_size_in_gbs
  node_disk_expansion_enabled = var.node_disk_expansion_enabled
  ssh_public_key              = var.ssh_public_key
  freeform_tags               = var.freeform_tags
  always_free_validation_id   = terraform_data.always_free_validation.id
}

# ──────────────────────────────────────────────────────────────────────────────
# Node Readiness Gate
# OKE marks the node pool resource complete before worker nodes finish their
# cloud-init (oci-growfs + oke-init.sh) and register as Ready. Without this
# gate, Helm releases time out waiting for pods that cannot be scheduled yet.
# This local-exec generates a temporary kubeconfig and blocks until every node
# in the pool reports Ready, then Helm deployments proceed in parallel.
# ──────────────────────────────────────────────────────────────────────────────

resource "terraform_data" "wait_for_nodes" {
  depends_on = [module.oke]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      KUBECONFIG_TMP="$(mktemp /tmp/oke-kubeconfig-XXXXXX.yaml)"
      trap 'rm -f "$KUBECONFIG_TMP"' EXIT
      oci ce cluster create-kubeconfig \
        --cluster-id ${module.oke.cluster_id} \
        --region ${split(".", module.oke.cluster_id)[3]} \
        --token-version 2.0.0 \
        --kube-endpoint PUBLIC_ENDPOINT \
        --file "$KUBECONFIG_TMP"
      echo "Waiting for all nodes to become Ready (timeout 15 min)..."
      KUBECONFIG="$KUBECONFIG_TMP" kubectl wait \
        --for=condition=Ready node --all --timeout=900s
      echo "All nodes Ready."
    EOT
  }
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

  # Reuse the exec credential plugin invocation that OCI itself emits in the
  # generated kubeconfig. This avoids brittle string parsing of the cluster
  # OCID and stays correct even if OCI changes OCID layout in the future.
  kubeconfig_exec      = try(local.kubeconfig.users[0].user.exec, null)
  kubeconfig_exec_args = try(local.kubeconfig_exec.args, [])
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
      args        = local.kubeconfig_exec_args
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
    args        = local.kubeconfig_exec_args
  }
}

resource "helm_release" "metrics_server" {
  count = var.enable_metrics_server ? 1 : 0

  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = var.metrics_server_chart_version
  namespace  = "kube-system"

  timeout         = 600
  cleanup_on_fail = true

  depends_on = [terraform_data.wait_for_nodes]
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
}

# Namespace is managed explicitly so that Terraform controls its lifecycle.
# The Helm release sets create_namespace = false and depends on this resource,
# which guarantees the namespace exists before chart installation and — crucially —
# is NOT deleted until after the Helm release is fully destroyed.
resource "kubernetes_namespace_v1" "nfs_storage" {
  count = var.enable_nfs_storage ? 1 : 0

  metadata {
    name = "nfs-storage"
  }

  depends_on = [terraform_data.wait_for_nodes]
}

# Explicit Terraform-managed PVC for the NFS server's backing OCI Block Volume.
#
# Why explicit rather than letting the Helm chart create it:
# The Helm chart uses a StatefulSet volumeClaimTemplate, which creates a PVC that
# Terraform has no visibility into. On destroy, Helm uninstall signals Kubernetes
# to delete the StatefulSet but returns immediately — the CSI driver's DeleteVolume
# gRPC call (which deletes the OCI Block Volume via OCI API) is still in-flight.
# Terraform then destroys the node pool, killing the CSI controller pod, aborting
# the API call, and leaving a 136 GB orphaned OCI Block Volume.
#
# With an explicit PVC, Terraform's kubernetes provider destroy BLOCKS until the
# PVC object is fully removed from the API server — which only happens after the
# CSI driver confirms the OCI Block Volume is deleted. This guarantees no orphans.
#
# Destroy order enforced by depends_on on the Helm release:
#   helm_release.nfs_server_provisioner  (Helm uninstall: NFS pod stops,
#     ↓                                   pvc-protection finalizer clears)
#   kubernetes_persistent_volume_claim_v1.nfs_backing  (Terraform blocks ~30s
#     ↓                                                 until OCI volume deleted)
#   module.oke (node pool)               (OCI Block Volume is already gone)
resource "kubernetes_persistent_volume_claim_v1" "nfs_backing" {
  count = var.enable_nfs_storage ? 1 : 0

  metadata {
    name      = "nfs-backing"
    namespace = "nfs-storage"
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "oci-bv-xfs"
    resources {
      requests = {
        storage = "${var.nfs_volume_size_in_gbs}Gi"
      }
    }
  }

  # WaitForFirstConsumer: the PVC stays Pending until the NFS server pod is
  # scheduled to a node. Do not block apply waiting for binding — the Helm
  # release below will trigger the scheduling that causes the bind.
  wait_until_bound = false

  depends_on = [
    kubernetes_namespace_v1.nfs_storage,
    kubernetes_storage_class_v1.oci_bv_xfs,
  ]
}

resource "helm_release" "nfs_server_provisioner" {
  count = var.enable_nfs_storage ? 1 : 0

  name       = "nfs-server-provisioner"
  repository = null
  chart      = "${path.module}/charts"
  namespace  = "nfs-storage"
  # Namespace lifecycle is owned by kubernetes_namespace_v1.nfs_storage above.
  create_namespace = false

  timeout         = 900
  cleanup_on_fail = true

  values = [yamlencode({
    persistence = {
      enabled       = true
      existingClaim = "nfs-backing"
    }
    storageClass = {
      name         = "nfs"
      defaultClass = true
    }
    extraArgs = {
      "enable-xfs-quota" = true
    }
    securityContext = {
      capabilities = {
        add = ["DAC_READ_SEARCH", "SYS_RESOURCE", "SYS_ADMIN"]
      }
    }
    # Conservative resource bounds to keep the privileged NFS server from
    # starving other workloads on the single Always Free worker node. The
    # provisioner is a known single replica (see README), so throttling it is
    # an availability trade-off, not a scalability one.
    resources = {
      requests = {
        cpu    = "100m"
        memory = "256Mi"
      }
      limits = {
        cpu    = "1000m"
        memory = "2Gi"
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

  # depends_on on the PVC (not just storage_class) is the key to correct destroy
  # ordering: Helm release is destroyed first (stops the NFS pod so
  # pvc-protection finalizer clears), then the PVC resource is destroyed (Terraform
  # blocks until CSI confirms the OCI Block Volume is deleted), and only then does
  # Terraform proceed to destroy the node pool.
  depends_on = [
    terraform_data.wait_for_nodes,
    kubernetes_persistent_volume_claim_v1.nfs_backing,
  ]
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
}

resource "kubernetes_namespace_v1" "tunnel" {
  metadata {
    name = var.cloudflare_tunnel_namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

resource "kubernetes_namespace_v1" "tailscale" {
  metadata {
    name = var.tailscale_namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
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
    # Ignore only the fields the controller mutates after binding so legitimate
    # in-place changes (e.g. requests.storage when expanding) are not silently
    # dropped by Terraform.
    ignore_changes = [
      spec[0].volume_name,
      spec[0].selector,
    ]
  }

  depends_on = [helm_release.nfs_server_provisioner, kubernetes_namespace_v1.n8n]
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
    N8N_PROTOCOL       = "http"
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

  timeout         = 600
  cleanup_on_fail = true

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

    # Additional env vars not covered by secretRefs
    config = {
      extraEnv = [
        { name = "WEBHOOK_URL", value = "https://${var.n8n_host}/" },
      ]
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

  depends_on = [helm_release.nfs_server_provisioner, kubernetes_namespace_v1.n8n, kubernetes_secret_v1.n8n_secrets, kubernetes_persistent_volume_claim_v1.n8n_data]

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
            read_only_root_filesystem  = true
            run_as_non_root            = true
            run_as_user                = 65532
            capabilities {
              drop = ["ALL"]
            }
          }

          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }
        }

        volume {
          name = "tmp"
          empty_dir {}
        }
      }
    }
  }

  depends_on = [terraform_data.wait_for_nodes, kubernetes_namespace_v1.tunnel, kubernetes_secret_v1.cloudflare_tunnel]
}

# ──────────────────────────────────────────────────────────────────────────────
# Tailscale Exit Node + Subnet Router
# ──────────────────────────────────────────────────────────────────────────────

resource "helm_release" "tailscale_operator" {
  count = var.enable_tailscale ? 1 : 0

  name             = "tailscale-operator"
  repository       = "https://pkgs.tailscale.com/helmcharts"
  chart            = "tailscale-operator"
  version          = var.tailscale_operator_chart_version
  namespace        = var.tailscale_namespace
  create_namespace = false

  timeout         = 600
  cleanup_on_fail = true

  values = [sensitive(yamlencode({
    oauth = {
      clientId     = var.tailscale_oauth_client_id
      clientSecret = var.tailscale_oauth_client_secret
    }
  }))]

  depends_on = [terraform_data.wait_for_nodes, kubernetes_namespace_v1.tailscale]

  lifecycle {
    precondition {
      condition     = var.tailscale_oauth_client_id != null
      error_message = "tailscale_oauth_client_id is required when enable_tailscale is true. Create an OAuth client at Tailscale Admin → Settings → OAuth Clients."
    }
    precondition {
      condition     = var.tailscale_oauth_client_secret != null
      error_message = "tailscale_oauth_client_secret is required when enable_tailscale is true."
    }
  }
}

# The Connector CRD is installed by the Helm release above. Using local-exec
# (rather than kubernetes_manifest) avoids plan-time CRD validation failures
# when the operator has not yet been installed.
#
# triggers_replace causes Terraform to re-apply the Connector whenever the
# hostname or advertised routes change, so drift is corrected automatically.
resource "terraform_data" "tailscale_connector" {
  count = var.enable_tailscale ? 1 : 0

  triggers_replace = {
    hostname         = local.tailscale_hostname
    advertise_routes = join(",", sort(var.tailscale_advertise_routes))
    cluster_id       = module.oke.cluster_id
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      KUBECONFIG_TMP="$(mktemp /tmp/oke-kubeconfig-XXXXXX.yaml)"
      trap 'rm -f "$KUBECONFIG_TMP"' EXIT
      oci ce cluster create-kubeconfig \
        --cluster-id ${module.oke.cluster_id} \
        --region ${split(".", module.oke.cluster_id)[3]} \
        --token-version 2.0.0 \
        --kube-endpoint PUBLIC_ENDPOINT \
        --file "$KUBECONFIG_TMP"
      kubectl --kubeconfig "$KUBECONFIG_TMP" apply -f - <<YAML
apiVersion: tailscale.com/v1alpha1
kind: Connector
metadata:
  name: ${local.tailscale_hostname}
spec:
  hostname: ${local.tailscale_hostname}
  exitNode: true
  subnetRouter:
    advertiseRoutes:
${join("\n", [for r in var.tailscale_advertise_routes : "      - \"${r}\""])}
YAML
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      set -e
      KUBECONFIG_TMP="$(mktemp /tmp/oke-kubeconfig-XXXXXX.yaml)"
      trap 'rm -f "$KUBECONFIG_TMP"' EXIT
      oci ce cluster create-kubeconfig \
        --cluster-id ${self.triggers_replace.cluster_id} \
        --region ${split(".", self.triggers_replace.cluster_id)[3]} \
        --token-version 2.0.0 \
        --kube-endpoint PUBLIC_ENDPOINT \
        --file "$KUBECONFIG_TMP" 2>/dev/null || true
      kubectl --kubeconfig "$KUBECONFIG_TMP" \
        delete connector ${self.triggers_replace.hostname} --ignore-not-found 2>/dev/null || true
    EOT
  }

  depends_on = [helm_release.tailscale_operator]
}
