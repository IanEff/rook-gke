# Tempo (trace storage), feeding thump's own self-observability — Phase B / Track B
# (~/Documents/vault/Projects/thump/phase-b-act-and-observe-guide.md, "B0 · Infra: Tempo +
# an OTel collector on rook-gke"). Unlike Prometheus/Loki, this isn't watching Ceph — it's
# where rattle/clank/hiss/thump export their own trace of each incident, keyed by the
# divergence Fingerprint as the trace_id.
#
# Off-Ceph storage: standard-rwo (GCE PD), same circularity ruling as loki.tf and NATS's
# PVC — the telemetry backend must not depend on the Ceph cluster under test.
#
# No separate OTel Collector deployment: the chart's Tempo binary already exposes native
# OTLP receivers (grpc :4317, http :4318) by default, and thump's beats are a handful of
# low-QPS Go processes emitting their own spans directly via the OTel SDK — there's no
# sampling/enrichment/fan-out need that would justify a second workload's footprint on
# nodes already tight on limits headroom (see README "Known GKE Gotchas" / _system/log.md
# 2026-07-08). Beats point straight at tempo.monitoring.svc.cluster.local:4317.
#
# Chart version verified live against `helm search repo grafana/tempo` on 2026-07-09 —
# re-check before bumping blindly.

resource "helm_release" "tempo" {
  name       = "tempo"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "tempo"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  version    = "1.24.4"

  values = [
    <<EOF
tempo:
  retention: 24h
  resources:
    requests: {cpu: 25m, memory: 64Mi}
    limits: {cpu: 200m, memory: 256Mi}
  storage:
    trace:
      backend: local
      local:
        path: /var/tempo/traces
      wal:
        path: /var/tempo/wal
  # OTLP receivers are enabled by default (grpc :4317, http :4318) — this is the
  # endpoint thump's beats push spans to directly.

persistence:
  enabled: true
  storageClassName: standard-rwo
  size: 5Gi

serviceMonitor:
  enabled: false
EOF
  ]
}
