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
    # Prerequisites — run BEFORE terraform apply with enable_n8n = true:
    # 1. Edit k8s/n8n-secrets.yaml and k8s/cloudflare-tunnel-secret.yaml with your values
    # 2. Apply manifests:
    kubectl apply -f k8s/namespace.yaml
    kubectl apply -f k8s/n8n-secrets.yaml
    kubectl apply -f k8s/cloudflare-tunnel-secret.yaml
  EOT
}
