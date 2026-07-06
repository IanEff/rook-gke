resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
  }
  depends_on = [google_container_node_pool.primary_nodes]
}

resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  version    = "61.3.0"

  set {
    name  = "prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues"
    value = "false"
  }
}

resource "helm_release" "sloth" {
  name       = "sloth"
  repository = "https://slok.github.io/sloth"
  chart      = "sloth"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  version    = "0.10.0"

  depends_on = [helm_release.kube_prometheus_stack]
}

resource "kubernetes_config_map" "ceph_topology_catalog" {
  metadata {
    name      = "ceph-topology-catalog"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    "catalog-info.yaml" = file("${path.module}/k8s/topology-catalog/catalog-info.yaml")
  }
}
