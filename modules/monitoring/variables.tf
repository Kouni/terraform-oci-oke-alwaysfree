variable "grafana_cloud_prometheus_url" {
  description = "Grafana Cloud Prometheus remote write endpoint (e.g. https://prometheus-prod-xx-xxx.grafana.net/api/prom/push)"
  type        = string
}

variable "grafana_cloud_prometheus_username" {
  description = "Grafana Cloud Prometheus instance ID (numeric). Found in Grafana Cloud → Prometheus → Details"
  type        = string
}

variable "grafana_cloud_loki_url" {
  description = "Grafana Cloud Loki push endpoint (e.g. https://logs-prod-xxx.grafana.net/loki/api/v1/push)"
  type        = string
}

variable "grafana_cloud_loki_username" {
  description = "Grafana Cloud Loki instance ID (numeric). Found in Grafana Cloud → Loki → Details"
  type        = string
}

variable "grafana_cloud_api_key" {
  description = "Grafana Cloud API token with MetricsPublisher and LogsPublisher scopes"
  type        = string
  sensitive   = true
}

variable "namespace" {
  description = "Kubernetes namespace for monitoring components"
  type        = string
  default     = "monitoring"
}

variable "alloy_chart_version" {
  description = "Grafana Alloy Helm chart version. If null, uses the latest available version"
  type        = string
  default     = null
}
