# rook-gke lifecycle wrapper. `just` alone lists recipes.

set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

# Initialize/reinitialize providers. Idempotent -- safe to run before every
# other recipe, which is exactly the point (see `destroy` below).
# Init/reinit providers.
init:
    tofu init

fmt:
    tofu fmt -recursive

validate: init
    tofu validate

plan: init
    tofu plan

apply: init
    tofu apply

# `.terraform/` is gitignored and never survives a fresh clone or a pruned
# cache, so `tofu destroy` run without reinitializing first fails partway
# through with "Required plugins are not installed" -- but only *after* it's
# already started deleting Kubernetes-provider resources. That leaves Rook's
# CephCluster/CephObjectStore CRs stuck Terminating with no operator left to
# ever clear their finalizers (lived stuck for 28h on 2026-07-08/09 before
# being hand-recovered). Always init first so destroy either fully runs or
# never starts.
# Tear down everything (always reinits first).
destroy: init
    tofu destroy -auto-approve

credentials: init
    eval "$(tofu output -raw get_credentials_command)"

gen-slos:
    ./scripts/gen_slos.sh
    kubectl apply -f k8s/sloth/prometheus-rules.yaml

# Tear down gcloud resources using gcloud cli
pull-ripcord:
    ./scripts/ripcord.sh
