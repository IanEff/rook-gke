# rook-gke lifecycle wrapper. `just` alone lists recipes.

set shell := ["bash", "-euo", "pipefail", "-c"]

# The kubernetes/helm providers (providers.tf) exec `gke-gcloud-auth-plugin` to
# authenticate. `gcloud components install` drops that binary under the SDK's
# own bin/ dir, but neither Homebrew's gcloud cask nor `gcloud` itself symlinks
# it into a directory that's on PATH by default (fish in particular never
# sources gcloud's bash/zsh path.*.inc snippets) -- so `tofu apply`/`destroy`
# fail with "executable not found" even though `gcloud` and the plugin are
# both installed. Prepend the SDK's bin/ dir here so every recipe below finds
# it regardless of the caller's shell/PATH setup.
export PATH := `gcloud info --format='value(installation.sdk_root)' 2>/dev/null`  + "/bin:" + env_var('PATH')

default:
    @just --list

# One-shot bootstrap: apply everything (VPC through Rook-Ceph and monitoring),
# then wire up kubectl so it's usable immediately after. This is the only
# command needed to go from nothing to a working cluster. Still asks for the
# interactive "yes" apply confirmation below -- it's creating real, billed
# cloud resources, so that gate stays even here.
up: apply credentials
    @echo
    @echo "Cluster is up, kubectl is pointed at it. Sanity check:"
    @kubectl get nodes

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

# Fetches kubeconfig, and makes sure gke-gcloud-auth-plugin resolves from a
# plain shell too -- see scripts/link_auth_plugin.sh for why that's a separate
# step from the justfile's own PATH export.
credentials: init
    eval "$(tofu output -raw get_credentials_command)"
    ./scripts/link_auth_plugin.sh

gen-slos:
    ./scripts/gen_slos.sh
    kubectl apply -f k8s/sloth/prometheus-rules.yaml

# Emergency teardown via gcloud CLI directly, bypassing OpenTofu -- for when
# `just destroy` can't run (broken .terraform/, unresponsive cluster API,
# etc). Deletes the cluster, any orphaned PVC-backed disks (Rook/Loki/Tempo),
# firewall, subnet, and VPC, then verifies each is actually gone and clears
# the now-stale local terraform.tfstate. See scripts/ripcord.sh.
pull-ripcord:
    ./scripts/ripcord.sh
