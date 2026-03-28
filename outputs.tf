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

output "n8n_setup_instructions" {
  description = "Instructions to create required K8s secrets before enabling n8n"
  value       = <<-EOT
    # Prerequisites — run BEFORE terraform apply:
    #
    # 1. Cloudflare Tunnel (for enable_cloudflare_tunnel = true):
    kubectl apply -f k8s/tunnel-namespace.yaml
    kubectl apply -f k8s/cloudflare-tunnel-secret.yaml
    #
    # 2. n8n (for enable_n8n = true):
    kubectl apply -f k8s/namespace.yaml
    kubectl apply -f k8s/n8n-secrets.yaml
  EOT
}
