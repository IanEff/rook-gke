# Loki (log storage) + Promtail (log shipper), feeding thump's clank `loki` evidence
# tool — the Stage 4 "second blast-radius axis" follow-up
# (~/Documents/vault/Projects/thump/phase2-converge-rook-gke-guide.md). This mirrors
# ceph-lab's own already-shipped telemetry design: Loki was scoped there as the
# evidence-tool log source (not rattle's blast-radius axis — that used Hubble, absent
# here), monolithic/single-binary, small, off-Ceph-storage. Same ruling applies on GKE.
#
# Off-Ceph storage: standard-rwo (GCE PD), NOT rook-raw-block or the rook-ceph-bucket
# RGW class — a Ceph incident must not take out the tool watching Ceph (the same
# circularity ruling NATS's PVC already obeys).
#
# Chart versions verified live against `helm search repo grafana/{loki,promtail}` on
# 2026-07-08 — re-check before bumping blindly.

resource "helm_release" "loki" {
  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  version    = "7.0.0"

  values = [
    <<EOF
deploymentMode: SingleBinary

loki:
  auth_enabled: false
  commonConfig:
    replication_factor: 1
  storage:
    type: filesystem
  # useTestSchema is the chart's own escape hatch for "testing or playing around" —
  # exactly this cluster's posture; a hand-rolled schemaConfig buys nothing here.
  useTestSchema: true
  limits_config:
    retention_period: 24h
  compactor:
    retention_enabled: true
    delete_request_store: filesystem

singleBinary:
  replicas: 1
  persistence:
    enabled: true
    storageClass: standard-rwo
    size: 5Gi

# SimpleScalable targets must be explicitly zeroed or the chart's own validation
# refuses to render ("more than zero replicas for both single binary and SSD targets").
read:
  replicas: 0
write:
  replicas: 0
backend:
  replicas: 0

# Memcached sidecars the chart enables by default — unnecessary weight for a
# low-traffic test cluster already tight on per-node headroom.
resultsCache:
  enabled: false
chunksCache:
  enabled: false
test:
  enabled: false
lokiCanary:
  enabled: false
monitoring:
  selfMonitoring:
    enabled: false
  lokiCanary:
    enabled: false
EOF
  ]
}

# Grafana's promtail chart is upstream-deprecated in favor of Grafana Alloy, but
# kept here to match ceph-lab's own resolved choice ("skip Alloy, use narrow
# tools... Promtail, well-trodden for Loki") rather than diverging for its own sake.
resource "helm_release" "promtail" {
  name       = "promtail"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "promtail"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  version    = "6.17.1"

  depends_on = [helm_release.loki]

  values = [
    <<EOF
config:
  clients:
    - url: http://loki-gateway.monitoring.svc.cluster.local/loki/api/v1/push
  snippets:
    # Rook already sets these two labels on every Ceph daemon pod (mon/osd/mgr/rgw/mds)
    # natively (confirmed live via `kubectl -n rook-ceph get pods --show-labels`) — no
    # custom instrumentation needed, just copy them from pod labels to log labels.
    extraRelabelConfigs:
      - source_labels: [__meta_kubernetes_pod_label_ceph_daemon_id]
        target_label: ceph_daemon_id
      - source_labels: [__meta_kubernetes_pod_label_ceph_daemon_type]
        target_label: ceph_daemon_type
EOF
  ]
}
