output "namespace" {
  description = "Kubernetes namespace where monitoring components are deployed"
  value       = kubernetes_namespace_v1.this.metadata[0].name
}

output "alloy_status" {
  description = "Grafana Alloy Helm release status (e.g., 'deployed', 'failed'). Check this to verify the monitoring stack deployed successfully"
  value       = helm_release.alloy.status
}
