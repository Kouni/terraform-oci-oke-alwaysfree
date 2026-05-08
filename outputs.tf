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
  value       = one(module.budget[*].budget_id)
}

output "n8n_namespace" {
  description = "Kubernetes namespace for n8n (always created; PVC and namespace persist even when enable_n8n = false)"
  value       = var.n8n_namespace
}

output "node_pool_id" {
  description = "The OCID of the OKE node pool"
  value       = module.oke.node_pool_id
}

