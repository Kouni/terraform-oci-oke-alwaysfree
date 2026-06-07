output "cluster_id" {
  description = "The OCID of the OKE cluster"
  value       = oci_containerengine_cluster.this.id
}

output "cluster_endpoint" {
  description = "The Kubernetes API endpoint of the OKE cluster (null if endpoint is not yet available)"
  value       = try("https://${oci_containerengine_cluster.this.endpoints[0].public_endpoint}", null)
}

output "node_pool_id" {
  description = "The OCID of the OKE node pool"
  value       = oci_containerengine_node_pool.this.id
}

output "kubeconfig_command" {
  description = "OCI CLI command to generate kubeconfig for this cluster"
  # Region extracted from cluster OCID: ocid1.<type>.<realm>.<region>.<unique_id>
  value = "oci ce cluster create-kubeconfig --cluster-id ${oci_containerengine_cluster.this.id} --region ${split(".", oci_containerengine_cluster.this.id)[3]} --token-version 2.0.0 --kube-endpoint PUBLIC_ENDPOINT"
}

# ── Outputs used by migration.tf (blue-green migration support) ──

output "kubernetes_version" {
  description = "Resolved Kubernetes version used by the cluster and node pool."
  value       = local.kubernetes_version
}

output "node_image_id" {
  description = "OCID of the latest OKE-optimised ARM image used by the node pool."
  value       = local.latest_arm_image_id
}
