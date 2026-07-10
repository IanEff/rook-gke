#!/usr/bin/env bash
#
# Emergency teardown of every gcloud resource this repo creates, bypassing
# OpenTofu entirely (`just destroy` needs a working `.terraform/` and a
# responsive Kubernetes API -- this doesn't, which is the point of a
# ripcord). Each resource type is deleted and then independently re-listed
# at the end so you get a real PASS/FAIL instead of trusting that individual
# `gcloud ... delete` calls did what they claimed.
#
# Deliberately manual and itemized rather than clever: every resource this
# repo can create is named explicitly below, cross-referenced to the .tf
# file that creates it, so a new resource type added later is easy to slot
# in rather than silently falling through a "delete everything" filter that
# might also catch other infra sharing this project (this sandbox project
# also hosts unrelated networks -- vpc-us-central, vpc-us-east -- that must
# never be touched here).

set -uo pipefail

# Always run from repo root regardless of invocation cwd, since the
# terraform.tfstate cleanup at the end uses a path relative to it.
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

PROJECT_ID=${PROJECT_ID:-"terraform-sandbox-430820"}
REGION=${REGION:-"us-central1"}
CLUSTER_NAME=${CLUSTER_NAME:-"rook-ceph-gke"}

# Namespaces this repo's Terraform creates (rook.tf's kubernetes_namespace.rook_ceph,
# telemetry.tf's kubernetes_namespace.monitoring) -- anything with a PersistentVolumeClaim
# lives in one of these two. Used below to scope the orphaned-disk sweep so it can never
# touch a disk belonging to some other cluster/workload in this shared sandbox project.
NAMESPACES=("rook-ceph" "monitoring")

echo "Project:  ${PROJECT_ID}"
echo "Region:   ${REGION}"
echo "Cluster:  ${CLUSTER_NAME}"
echo

# --- 1. GKE cluster (gke.tf: google_container_cluster.primary, google_container_node_pool.primary_nodes) ---
# Deleting the cluster cascades the node pool and its underlying VMs/instance groups --
# nothing further to do for those.
echo "[1/5] Deleting GKE cluster..."
gcloud container clusters delete "${CLUSTER_NAME}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --quiet 2>&1 || echo "  -> already deleted or not found."
echo

# --- 2. Orphaned PVC-backed persistent disks ---
# Deleting the cluster this way (instead of letting Kubernetes delete each PVC first)
# skips the pd.csi.storage.gke.io driver's own cleanup, so any dynamically-provisioned
# disk backing a PVC in rook-ceph/ or monitoring/ (Rook OSDs/mons, Loki, Tempo,
# kube-prometheus-stack) is orphaned and left billing. Scoped to disks whose GKE-CSI
# description names one of THIS repo's namespaces -- never a blanket "all disks in the
# project" sweep.
echo "[2/5] Sweeping orphaned PVC-backed persistent disks..."
disk_filter=""
for ns in "${NAMESPACES[@]}"; do
  term="description~\"created-for/pvc/namespace\\\":\\\"${ns}\""
  disk_filter="${disk_filter:+${disk_filter} OR }${term}"
done
mapfile -t orphaned_disks < <(gcloud compute disks list \
  --project="${PROJECT_ID}" \
  --filter="${disk_filter}" \
  --format="csv[no-heading](name,zone.basename())" 2>/dev/null || true)

if [ "${#orphaned_disks[@]}" -eq 0 ]; then
  echo "  -> none found."
else
  for entry in "${orphaned_disks[@]}"; do
    disk_name="${entry%,*}"
    disk_zone="${entry#*,}"
    echo "  -> deleting disk ${disk_name} (${disk_zone})..."
    gcloud compute disks delete "${disk_name}" \
      --zone="${disk_zone}" \
      --project="${PROJECT_ID}" \
      --quiet 2>&1 || echo "     failed -- check manually."
  done
fi
echo

# --- 3. Firewall rule (vpc.tf: google_compute_firewall.allow_internal) ---
echo "[3/5] Deleting firewall rule..."
gcloud compute firewall-rules delete "${CLUSTER_NAME}-allow-internal" \
  --project="${PROJECT_ID}" \
  --quiet 2>&1 || echo "  -> already deleted or not found."
echo

# --- 4. Subnetwork (vpc.tf: google_compute_subnetwork.subnet) ---
echo "[4/5] Deleting subnetwork..."
gcloud compute networks subnets delete "${CLUSTER_NAME}-subnet" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --quiet 2>&1 || echo "  -> already deleted or not found."
echo

# --- 5. VPC network (vpc.tf: google_compute_network.vpc) ---
echo "[5/5] Deleting VPC network..."
gcloud compute networks delete "${CLUSTER_NAME}-vpc" \
  --project="${PROJECT_ID}" \
  --quiet 2>&1 || echo "  -> already deleted or not found."
echo

# --- Verify: re-list every resource type above independently. A delete call
# reporting success doesn't guarantee the API converged instantly, and a delete
# call reporting failure doesn't always mean the resource is still there (it
# might already have been gone) -- so trust a fresh list, not the delete exit code.
echo "Verifying teardown..."
status=0

cluster_left=$(gcloud container clusters list --project "${PROJECT_ID}" \
  --filter="name=${CLUSTER_NAME}" --format="value(name)" 2>/dev/null || true)
if [ -n "$cluster_left" ]; then
  echo "  [FAIL] GKE cluster still present."
  status=1
else
  echo "  [ok]   GKE cluster gone."
fi

disks_left=$(gcloud compute disks list --project "${PROJECT_ID}" \
  --filter="${disk_filter}" --format="value(name)" 2>/dev/null || true)
if [ -n "$disks_left" ]; then
  echo "  [FAIL] Orphaned disks still present: $(echo "$disks_left" | tr '\n' ' ')"
  status=1
else
  echo "  [ok]   No orphaned PVC-backed disks."
fi

fw_left=$(gcloud compute firewall-rules list --project "${PROJECT_ID}" \
  --filter="name=${CLUSTER_NAME}-allow-internal" --format="value(name)" 2>/dev/null || true)
if [ -n "$fw_left" ]; then
  echo "  [FAIL] Firewall rule still present."
  status=1
else
  echo "  [ok]   Firewall rule gone."
fi

subnet_left=$(gcloud compute networks subnets list --project "${PROJECT_ID}" \
  --filter="name=${CLUSTER_NAME}-subnet" --format="value(name)" 2>/dev/null || true)
if [ -n "$subnet_left" ]; then
  echo "  [FAIL] Subnetwork still present."
  status=1
else
  echo "  [ok]   Subnetwork gone."
fi

vpc_left=$(gcloud compute networks list --project "${PROJECT_ID}" \
  --filter="name=${CLUSTER_NAME}-vpc" --format="value(name)" 2>/dev/null || true)
if [ -n "$vpc_left" ]; then
  echo "  [FAIL] VPC network still present."
  status=1
else
  echo "  [ok]   VPC network gone."
fi

echo
if [ "$status" -eq 0 ]; then
  # ripcord bypasses OpenTofu entirely, so terraform.tfstate now describes
  # resources that no longer exist -- a subsequent `tofu apply`/`plan` would
  # try to refresh state against a cluster API endpoint that's gone. Since
  # this repo's own state files are gitignored/ephemeral by design (see
  # CLAUDE.md), reset them here too so `just apply` starts clean instead of
  # erroring out on refresh.
  if [ -f terraform.tfstate ] || [ -f terraform.tfstate.backup ]; then
    rm -f terraform.tfstate terraform.tfstate.backup
    echo "Local terraform.tfstate cleared (was describing now-deleted resources)."
  fi
  echo "Ripcord complete -- all resources confirmed gone."
else
  echo "Ripcord finished with leftovers -- see [FAIL] lines above. Investigate manually before re-applying."
  echo "Local terraform.tfstate left untouched since teardown was incomplete."
fi
exit "$status"
