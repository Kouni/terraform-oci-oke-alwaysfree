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
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      KUBECONFIG_TMP="$(mktemp /tmp/oke-kubeconfig-XXXXXX.yaml)"
      trap 'rm -f "$KUBECONFIG_TMP"' EXIT

      REGION="${split(".", module.oke.cluster_id)[3]}"

      oci ce cluster create-kubeconfig \
        --cluster-id ${module.oke.cluster_id} \
        --region "$REGION" \
        --token-version 2.0.0 \
        --kube-endpoint PUBLIC_ENDPOINT \
        --file "$KUBECONFIG_TMP"

      export KUBECONFIG="$KUBECONFIG_TMP"

      echo "Waiting for all nodes to become Ready (timeout 15 min)..."
      kubectl wait --for=condition=Ready node --all --timeout=900s
      echo "All nodes Ready."

      # ── OKE CCM Topology Label Fallback ─────────────────────────────────────
      # OKE's Cloud Controller Manager must add topology labels and remove the
      # node.cloudprovider.kubernetes.io/uninitialized taint after each node
      # boots. When OKE internal migration fails (symptom: node label
      # last-migration-failure=get_kubesvc_failure), CCM never patches the node,
      # causing the csi-oci-node DaemonSet to crash and blocking all PVC
      # provisioning. This loop detects missing topology labels and applies them
      # directly from OCI instance metadata as a deterministic fallback.
      echo "Checking OKE CCM topology labels on all nodes..."
      for NODE_NAME in $(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
        ZONE=$(kubectl get node "$NODE_NAME" \
          -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null || true)
        if [ -n "$ZONE" ]; then
          echo "  $NODE_NAME: zone=$ZONE — OK"
          continue
        fi
        echo "  $NODE_NAME: topology labels absent — querying OCI instance metadata..."
        PROVIDER_ID=$(kubectl get node "$NODE_NAME" -o jsonpath='{.spec.providerID}')
        INSTANCE_OCID="$${PROVIDER_ID#oci://}"
        AD=$(oci compute instance get \
          --instance-id "$INSTANCE_OCID" --region "$REGION" \
          --query 'data."availability-domain"' --raw-output)
        FD=$(oci compute instance get \
          --instance-id "$INSTANCE_OCID" --region "$REGION" \
          --query 'data."fault-domain"' --raw-output)
        # Strip tenancy hash prefix (e.g. "SBLv:AP-TOKYO-1-AD-1" -> "AP-TOKYO-1-AD-1")
        AD_LABEL="$${AD#*:}"
        kubectl label node "$NODE_NAME" \
          "topology.kubernetes.io/zone=$AD_LABEL" \
          "topology.kubernetes.io/region=$REGION" \
          "failure-domain.beta.kubernetes.io/zone=$AD_LABEL" \
          "failure-domain.beta.kubernetes.io/region=$REGION" \
          "oci.oraclecloud.com/fault-domain=$FD" \
          --overwrite
        kubectl annotate node "$NODE_NAME" \
          "node.info/availability-domain=$AD" \
          "oci.oraclecloud.com/availability-domain=$AD" \
          --overwrite
        kubectl taint node "$NODE_NAME" \
          "node.cloudprovider.kubernetes.io/uninitialized=true:NoSchedule-" 2>/dev/null || true
        echo "  $NODE_NAME patched: zone=$AD_LABEL region=$REGION fault-domain=$FD"
      done

      # ── CSI Node Plugin Health Check ─────────────────────────────────────────
      # After topology label patching, the csi-oci-node DaemonSet may need a
      # restart to re-read node annotations. Verify readiness before Helm
      # releases proceed; trigger a rollout only if the pod is not yet healthy.
      echo "Waiting for csi-oci-node DaemonSet..."
      if ! kubectl rollout status daemonset/csi-oci-node \
           -n kube-system --timeout=60s 2>/dev/null; then
        echo "  csi-oci-node not yet Ready — restarting DaemonSet..."
        kubectl rollout restart daemonset/csi-oci-node -n kube-system
      fi
      kubectl rollout status daemonset/csi-oci-node -n kube-system --timeout=120s
      echo "CSI node plugin Ready — proceeding with Helm releases."
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

resource "helm_release" "nfs_server_provisioner" {
  count = var.enable_nfs_storage ? 1 : 0

  name             = "nfs-server-provisioner"
  repository       = null
  chart            = "${path.module}/charts"
  namespace        = "nfs-storage"
  create_namespace = true

  timeout         = 900
  cleanup_on_fail = true

  values = [yamlencode({
    persistence = {
      enabled      = true
      storageClass = "oci-bv-xfs"
      size         = "${var.nfs_volume_size_in_gbs}Gi"
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

  depends_on = [terraform_data.wait_for_nodes, kubernetes_storage_class_v1.oci_bv_xfs]
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
    # Prevent accidental data loss — must be manually removed from state before destroy.
    prevent_destroy = true
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
