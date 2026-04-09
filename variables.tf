# OCI Authentication
# Option 1: config_file_profile (recommended) — only need compartment_ocid
# Option 2: Direct credentials — set tenancy_ocid, user_ocid, fingerprint, private_key_path, region

variable "config_file_profile" {
  description = "OCI CLI config file profile name (e.g. \"DEFAULT\"). When set, tenancy/user/fingerprint/key/region are read from ~/.oci/config"
  type        = string
  default     = null
}

variable "tenancy_ocid" {
  description = "The OCID of the tenancy. Only required when not using config_file_profile"
  type        = string
  default     = null
}

variable "user_ocid" {
  description = "The OCID of the user calling the API. Only required when not using config_file_profile"
  type        = string
  default     = null
}

variable "fingerprint" {
  description = "Fingerprint for the API key pair. Only required when not using config_file_profile"
  type        = string
  default     = null
}

variable "private_key_path" {
  description = "Path to the private key file. Only required when not using config_file_profile"
  type        = string
  default     = null
}

variable "region" {
  description = "The OCI region. Only required when not using config_file_profile"
  type        = string
  default     = null
}

variable "compartment_ocid" {
  description = "The OCID of the compartment to create resources in"
  type        = string
}

# Cluster configuration

variable "cluster_name" {
  description = "Display name for the OKE cluster"
  type        = string
  default     = "alwaysfree-oke"
}

variable "kubernetes_version" {
  description = "Kubernetes version for the cluster. If null, uses the latest available version"
  type        = string
  default     = null
}

# Node pool configuration

variable "node_count" {
  description = "Number of worker nodes in the node pool"
  type        = number
  default     = 1

  validation {
    condition     = var.node_count >= 1
    error_message = "Node count must be at least 1."
  }
}

variable "node_ocpus" {
  description = "Number of OCPUs per worker node (ARM A1.Flex)"
  type        = number
  default     = 4

  validation {
    condition     = var.node_ocpus >= 1
    error_message = "Each node must have at least 1 OCPU."
  }
}

variable "node_memory_in_gbs" {
  description = "Memory in GBs per worker node (ARM A1.Flex)"
  type        = number
  default     = 24

  validation {
    condition     = var.node_memory_in_gbs >= 1
    error_message = "Each node must have at least 1 GB of memory."
  }
}

variable "boot_volume_size_in_gbs" {
  description = "Boot volume size in GBs per worker node. Boot + NFS volumes share the 200 GB Always Free block volume quota"
  type        = number
  default     = 64

  validation {
    condition     = var.boot_volume_size_in_gbs >= 50
    error_message = "Boot volume must be at least 50 GB."
  }
}

variable "ssh_public_key" {
  description = "SSH public key for worker node access. If null, SSH access is disabled"
  type        = string
  default     = null
}

# Network configuration

variable "vcn_cidr" {
  description = "CIDR block for the VCN. Must be 10.0.0.0/16 because subnet CIDRs are fixed"
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = var.vcn_cidr == "10.0.0.0/16"
    error_message = "vcn_cidr must be \"10.0.0.0/16\". Subnet CIDRs are hardcoded within this range."
  }
}

variable "enable_nat_gateway" {
  description = "Create a NAT Gateway (placeholder for future private-subnet migration). WARNING: NAT Gateway is NOT Always Free and will incur charges. Currently no route table references it because all subnets are public"
  type        = bool
  default     = false
}

# Budget alert

variable "enable_budget_alert" {
  description = "Enable OCI Budget alert as a cost safety net for Always Free accounts"
  type        = bool
  default     = true
}

variable "notification_email" {
  description = "Email address for budget alert notifications. Required when enable_budget_alert is true"
  type        = string
  default     = null
}

# Cluster add-ons

variable "enable_metrics_server" {
  description = "Deploy metrics-server to enable kubectl top pods/nodes resource metrics"
  type        = bool
  default     = true
}

# NFS Storage

variable "enable_nfs_storage" {
  description = "Deploy in-cluster NFS server with dynamic PV provisioning, backed by OCI Block Volume (shares the 200 GB Always Free block volume quota)"
  type        = bool
  default     = false
}

variable "nfs_volume_size_in_gbs" {
  description = "Size in GBs for the NFS backing block volume. Total block storage (boot + NFS) must not exceed 200 GB Always Free limit"
  type        = number
  default     = 136

  validation {
    condition     = var.nfs_volume_size_in_gbs >= 50
    error_message = "NFS volume must be at least 50 GB (OCI Block Volume minimum)."
  }
}

# Tags

variable "freeform_tags" {
  description = "Freeform tags applied to all resources"
  type        = map(string)
  default = {
    "alwaysfree" = "true"
  }
}

# n8n (workflow automation with Cloudflare Zero Trust Tunnel)

variable "enable_n8n" {
  description = "Deploy n8n workflow automation. Requires enable_nfs_storage = true and enable_cloudflare_tunnel = true"
  type        = bool
  default     = false
}

variable "n8n_namespace" {
  description = "Kubernetes namespace for n8n deployment"
  type        = string
  default     = "n8n"
}

variable "n8n_pvc_size" {
  description = "PVC size for n8n persistent data (SQLite DB, credentials, workflows). Allocated from NFS StorageClass"
  type        = string
  default     = "5Gi"

  validation {
    condition     = can(regex("^[1-9][0-9]*Gi$", var.n8n_pvc_size))
    error_message = "n8n_pvc_size must be a valid Kubernetes quantity in whole gibibytes (e.g. '5Gi', '10Gi')."
  }
}

variable "n8n_secret_name" {
  description = "Name of the K8s Secret (managed by Terraform) containing N8N_ENCRYPTION_KEY, N8N_HOST, N8N_PORT, N8N_PROTOCOL"
  type        = string
  default     = "n8n-secrets"
}

variable "n8n_encryption_key" {
  description = "N8N_ENCRYPTION_KEY value. For new deployments: generate with `openssl rand -hex 32`. For existing clusters: extract with `kubectl get secret n8n-secrets -n n8n -o jsonpath='{.data.N8N_ENCRYPTION_KEY}' | base64 -d`. Changing this value destroys all stored n8n credentials"
  type        = string
  default     = null
  sensitive   = true
}

variable "n8n_host" {
  description = "Public hostname for n8n (e.g. n8n.example.com), injected as N8N_HOST into the n8n-secrets Secret"
  type        = string
  default     = null
}

variable "cloudflared_secret_name" {
  description = "Name of the K8s Secret (managed by Terraform) containing TUNNEL_TOKEN for Cloudflare Zero Trust Tunnel"
  type        = string
  default     = "cloudflare-tunnel"
}

variable "cloudflare_tunnel_token" {
  description = "Cloudflare Zero Trust tunnel token (TUNNEL_TOKEN). Found in Cloudflare Dashboard → Networks → Tunnels → your tunnel → Configure"
  type        = string
  default     = null
  sensitive   = true
}

variable "n8n_chart_version" {
  description = "n8n Helm chart version. If null, uses the latest available version"
  type        = string
  default     = null
}

variable "n8n_image_tag" {
  description = "n8n container image tag (e.g. '1.94.1'). Defaults to 'latest' — pin a specific version for reproducible deployments"
  type        = string
  default     = "latest"
}

variable "cloudflared_image_tag" {
  description = "cloudflared container image tag (e.g. '2025.4.1'). Defaults to 'latest' — pin a specific version for reproducible deployments"
  type        = string
  default     = "latest"
}

# ──────────────── Grafana Cloud Monitoring ────────────────

variable "enable_alloy_to_grafana_cloud" {
  description = "Deploy Grafana Alloy and kube-state-metrics to ship metrics and logs to Grafana Cloud Free Plan"
  type        = bool
  default     = false
}

variable "grafana_cloud_prometheus_url" {
  description = "Grafana Cloud Prometheus remote write endpoint (e.g. https://prometheus-prod-xx-xxx.grafana.net/api/prom/push)"
  type        = string
  default     = null
}

variable "grafana_cloud_prometheus_username" {
  description = "Grafana Cloud Prometheus instance ID (numeric). Found in Grafana Cloud → Prometheus → Details"
  type        = string
  default     = null
}

variable "grafana_cloud_loki_url" {
  description = "Grafana Cloud Loki push endpoint (e.g. https://logs-prod-xxx.grafana.net/loki/api/v1/push)"
  type        = string
  default     = null
}

variable "grafana_cloud_loki_username" {
  description = "Grafana Cloud Loki instance ID (numeric). Found in Grafana Cloud → Loki → Details"
  type        = string
  default     = null
}

variable "grafana_cloud_api_key" {
  description = "Grafana Cloud API token with MetricsPublisher and LogsPublisher scopes"
  type        = string
  default     = null
  sensitive   = true
}

variable "monitoring_namespace" {
  description = "Kubernetes namespace for Grafana monitoring components"
  type        = string
  default     = "monitoring"
}

variable "alloy_chart_version" {
  description = "Grafana Alloy Helm chart version. If null, uses the latest available version"
  type        = string
  default     = null
}

variable "kube_state_metrics_chart_version" {
  description = "kube-state-metrics Helm chart version. If null, uses the latest available version"
  type        = string
  default     = null
}

# ──────────────── Cloudflare Tunnel ────────────────

variable "enable_cloudflare_tunnel" {
  description = "Deploy a shared Cloudflare Zero Trust Tunnel. Routes are configured in Cloudflare Dashboard"
  type        = bool
  default     = false
}

variable "cloudflare_tunnel_namespace" {
  description = "Kubernetes namespace for the shared Cloudflare Tunnel"
  type        = string
  default     = "tunnel"
}
