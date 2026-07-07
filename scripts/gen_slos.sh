#!/usr/bin/env bash
# rook-gke — gen_slos.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SLO_SPEC="$REPO_ROOT/k8s/sloth/prometheusservicelevels.yaml"
OUT_FILE="$REPO_ROOT/k8s/sloth/prometheus-rules.yaml"

command -v sloth >/dev/null 2>&1 || { echo "gen_slos.sh: 'sloth' CLI required" >&2; exit 1; }

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

sloth generate -i "$SLO_SPEC" --disable-alerts --no-color -o "$tmpdir/recording.k8s.yaml"
sloth generate -i "$SLO_SPEC" --disable-recordings --no-color -o "$tmpdir/alerting.k8s.yaml"

cat << 'EOF' > "$OUT_FILE"
# DO NOT EDIT BY HAND — run `./scripts/gen_slos.sh` after changing the source spec.
# This file contains the generated PrometheusRule objects for the Prometheus operator.
EOF

# Inject the release label before appending
if command -v yq >/dev/null 2>&1; then
    yq e '.metadata.labels.release = "kube-prometheus-stack"' "$tmpdir/recording.k8s.yaml" >> "$OUT_FILE"
    echo "---" >> "$OUT_FILE"
    yq e '.metadata.labels.release = "kube-prometheus-stack"' "$tmpdir/alerting.k8s.yaml" >> "$OUT_FILE"
else
    # Fallback to awk (insert release label right after metadata name/namespace/labels)
    awk '/^metadata:/ {in_meta=1} in_meta && /^  labels:/ {print; print "    release: kube-prometheus-stack"; in_meta=0; next} {print}' "$tmpdir/recording.k8s.yaml" >> "$OUT_FILE"
    echo "---" >> "$OUT_FILE"
    awk '/^metadata:/ {in_meta=1} in_meta && /^  labels:/ {print; print "    release: kube-prometheus-stack"; in_meta=0; next} {print}' "$tmpdir/alerting.k8s.yaml" >> "$OUT_FILE"
fi

echo "gen_slos.sh: generated $OUT_FILE"
