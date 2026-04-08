output "vcn_id" {
  description = "The OCID of the VCN"
  value       = module.network.vcn_id
}

output "cluster_id" {
  description = "The OCID of the OKE cluster"
  value       = module.oke.cluster_id
}

output "cluster_endpoint" {
  description = "The Kubernetes API endpoint of the OKE cluster"
  value       = module.oke.cluster_endpoint
}

output "kubeconfig_command" {
  description = "OCI CLI command to generate kubeconfig"
  value       = module.oke.kubeconfig_command
}

output "nfs_storage_class" {
  description = "NFS StorageClass name for dynamic PV provisioning (null if NFS storage is disabled)"
  value       = var.enable_nfs_storage ? "nfs" : null
}

output "budget_id" {
  description = "The OCID of the budget (null if budget alert is disabled)"
  value       = var.enable_budget_alert ? module.budget[0].budget_id : null
}

output "n8n_namespace" {
  description = "Kubernetes namespace where n8n is deployed (null if n8n is disabled)"
  value       = var.enable_n8n ? var.n8n_namespace : null
}

output "monitoring_namespace" {
  description = "Kubernetes namespace where monitoring components are deployed (null if monitoring is disabled)"
  value       = var.enable_grafana_monitoring ? module.monitoring[0].namespace : null
}

output "n8n_setup_instructions" {
  description = "Required terraform.tfvars variables for enabling n8n and Cloudflare Tunnel"
  value       = <<-EOT
    # Set these variables in terraform.tfvars before enabling n8n:
    #
    # enable_cloudflare_tunnel  = true
    # cloudflare_tunnel_token   = "<token from Cloudflare Dashboard → Networks → Tunnels>"
    #
    # enable_n8n                = true
    # n8n_host                  = "<your-n8n-hostname>"
    # n8n_encryption_key        = "<32-char random string — keep this safe, never rotate>"
  EOT
}
