# Infraestrutura, eventos, estado dos objetos e logs dos pods. O APM vem do agente na imagem.
resource "helm_release" "newrelic" {
  count = var.newrelic_license_key == "" ? 0 : 1

  name             = "newrelic"
  namespace        = "newrelic"
  create_namespace = true
  repository       = "https://helm-charts.newrelic.com"
  chart            = "nri-bundle"
  version          = "8.0.24"
  timeout          = 900

  set_sensitive {
    name  = "global.licenseKey"
    value = var.newrelic_license_key
  }

  set {
    name  = "global.cluster"
    value = var.newrelic_cluster_name
  }

  set {
    name  = "kube-state-metrics.enabled"
    value = "true"
  }

  set {
    name  = "nri-kube-events.enabled"
    value = "true"
  }

  set {
    name  = "newrelic-logging.enabled"
    value = "true"
  }

  set {
    name  = "nri-prometheus.enabled"
    value = "true"
  }

  depends_on = [aws_eks_node_group.principal, aws_eks_addon.essenciais]
}
