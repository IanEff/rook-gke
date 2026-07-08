#!/usr/bin/env bash
# rook-gke — gen_slos.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SLO_SPEC="$REPO_ROOT/k8s/sloth/prometheusservicelevels.yaml"
OUT_FILE="$REPO_ROOT/k8s/sloth/prometheus-rules.yaml"

command -v sloth >/dev/null 2>&1 || { echo "gen_slos.sh: 'sloth' CLI required" >&2; exit 1; }

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# One pass, not two: sloth already bundles the SLI-recording, meta-recording, and
# alerting groups into a single PrometheusRule per SLO. Generating recordings and
# alerts separately (as this used to do) produces two PrometheusRule objects with
# the *same* metadata.name/namespace — kubectl apply then applies them as the same
# object twice, and the second (alerts-only) pass silently replaces the first's
# .spec, dropping the recording rules `slo:current_burn_rate:ratio` depends on.
sloth generate -i "$SLO_SPEC" --no-color -o "$tmpdir/rules.k8s.yaml"

cat << 'EOF' > "$OUT_FILE"
# DO NOT EDIT BY HAND — run `./scripts/gen_slos.sh` after changing the source spec.
# This file contains the generated PrometheusRule objects for the Prometheus operator.
EOF

# Inject the release label
if command -v yq >/dev/null 2>&1; then
    yq e '.metadata.labels.release = "kube-prometheus-stack"' "$tmpdir/rules.k8s.yaml" >> "$OUT_FILE"
else
    # Fallback to awk (insert release label right after metadata name/namespace/labels)
    awk '/^metadata:/ {in_meta=1} in_meta && /^  labels:/ {print; print "    release: kube-prometheus-stack"; in_meta=0; next} {print}' "$tmpdir/rules.k8s.yaml" >> "$OUT_FILE"
fi

echo "gen_slos.sh: generated $OUT_FILE"
