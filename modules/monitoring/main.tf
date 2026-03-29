# ──────────────── Namespace ────────────────

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name = var.namespace
  }
}

# ──────────────── Grafana Cloud Credentials ────────────────

resource "kubernetes_secret_v1" "grafana_cloud" {
  metadata {
    name      = "grafana-cloud"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }

  data = {
    GRAFANA_CLOUD_PROMETHEUS_URL      = var.grafana_cloud_prometheus_url
    GRAFANA_CLOUD_PROMETHEUS_USERNAME = var.grafana_cloud_prometheus_username
    GRAFANA_CLOUD_LOKI_URL            = var.grafana_cloud_loki_url
    GRAFANA_CLOUD_LOKI_USERNAME       = var.grafana_cloud_loki_username
    GRAFANA_CLOUD_API_KEY             = var.grafana_cloud_api_key
  }
}

# ──────────────── kube-state-metrics ────────────────

resource "helm_release" "kube_state_metrics" {
  name       = "kube-state-metrics"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-state-metrics"
  version    = var.kube_state_metrics_chart_version
  namespace  = kubernetes_namespace_v1.this.metadata[0].name

  values = [yamlencode({
    resources = {
      requests = { cpu = "10m", memory = "32Mi" }
      limits   = { cpu = "100m", memory = "64Mi" }
    }

    # Collect only essential resource types to reduce memory usage
    collectors = [
      "daemonsets",
      "deployments",
      "namespaces",
      "nodes",
      "persistentvolumeclaims",
      "pods",
      "replicasets",
      "services",
      "statefulsets",
    ]
  })]
}

# ──────────────── Grafana Alloy ────────────────

resource "helm_release" "alloy" {
  name       = "alloy"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "alloy"
  version    = var.alloy_chart_version
  namespace  = kubernetes_namespace_v1.this.metadata[0].name

  values = [yamlencode({
    alloy = {
      configMap = {
        create = true
        content = templatefile("${path.module}/config.alloy.tftpl", {
          namespace = var.namespace
        })
      }

      envFrom = [{
        secretRef = {
          name = kubernetes_secret_v1.grafana_cloud.metadata[0].name
        }
      }]

      mounts = {
        varlog           = false
        dockercontainers = false
      }
    }

    controller = {
      type = "daemonset"
    }

    resources = {
      requests = { cpu = "50m", memory = "128Mi" }
      limits   = { cpu = "200m", memory = "256Mi" }
    }

    crds = {
      create = false
    }

    # Add nodes/proxy permission for kubelet & cAdvisor scraping via API proxy
    rbac = {
      clusterRules = [
        { apiGroups = [""], resources = ["nodes"], verbs = ["get", "list", "watch"] },
        { apiGroups = [""], resources = ["nodes/pods"], verbs = ["get", "list", "watch"] },
        { apiGroups = [""], resources = ["nodes/metrics"], verbs = ["get", "list", "watch"] },
        { apiGroups = [""], resources = ["nodes/proxy"], verbs = ["get"] },
        { nonResourceURLs = ["/metrics"], verbs = ["get"] },
      ]
    }
  })]

  depends_on = [helm_release.kube_state_metrics]
}
