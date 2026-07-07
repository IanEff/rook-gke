# System Log

## 2026-07-05

- **Initialization**: Initialized empty git repository in `/Users/ian/projects/ceph/rook-gke`.
- **Plan approved**: Implementation plan for provisioning GKE with Ubuntu-based nodes and raw block storage support was approved. Starting execution.
- **Execution Complete**:
  - Created OpenTofu configurations:
    - [providers.tf](file:///Users/ian/projects/ceph/rook-gke/providers.tf)
    - [variables.tf](file:///Users/ian/projects/ceph/rook-gke/variables.tf)
    - [vpc.tf](file:///Users/ian/projects/ceph/rook-gke/vpc.tf)
    - [gke.tf](file:///Users/ian/projects/ceph/rook-gke/gke.tf)
    - [outputs.tf](file:///Users/ian/projects/ceph/rook-gke/outputs.tf)
  - Created Kubernetes manifests:
    - [storage-class-raw.yaml](file:///Users/ian/projects/ceph/rook-gke/storage-class-raw.yaml)
    - [rook-cluster-osds-snippet.yaml](file:///Users/ian/projects/ceph/rook-gke/rook-cluster-osds-snippet.yaml)
  - Verified configurations:
    - Ran `tofu init` (successful).
    - Ran `tofu validate` (successful).
    - Ran `tofu plan` (successful, planning 6 resources to add).
- **Documentation**:
  - Created [README.md](file:///Users/ian/projects/ceph/rook-gke/README.md) file detailing the project features, setup constraints, directory structure, and user execution steps.

## 2026-07-06

- **Replicated Sloth SLOs**: Replicated Sloth SLO definitions from `ceph-lab` to `k8s/sloth/prometheusservicelevels.yaml`, adapting the `cluster: rook-ceph-gke` label for GKE deployment and trimming legacy context from descriptions.
- **Documentation Update**: Completely rewrote the `README.md` to reflect recent automated Helm deployment features (Rook and Telemetry stacks) and pod-to-pod firewall rules.
- **Chaos Engineering Docs**: Appended a section to `README.md` with explicit instructions on generating chaos to trigger the newly added Sloth SLOs (health, latency, availability, and ArgoCD sync).

## 2026-07-07

- **Telemetry rework (Antigravity/Gemini session)**: Ported Sloth from a live in-cluster controller to a build-time model (`scripts/gen_slos.sh` generates `k8s/sloth/prometheus-rules.yaml` from `k8s/sloth/prometheusservicelevels.yaml`, which was trimmed to just `ceph-health` and `ceph-rgw-availability`); rewrote `k8s/topology-catalog/catalog-info.yaml` for GKE nodes (dropped ceph-lab's argocd/cilium/cephfs entities) and authored `k8s/topology-catalog/state-queries.yaml` (PromQL per dependency, consumed by the `whir` resolver); reconciled the raw-block StorageClass onto `pd-balanced`, retiring `storage-class-raw.yaml` in favor of a `kubernetes_storage_class` resource in `rook.tf`.
- **Incident — cluster stuck in ERROR, state/GCP split-brain**: Mid-session, the agent killed a `tofu apply` ~27 minutes in, assuming GKE creation had hung (GKE regularly takes 30+ min in this project). This desynced Tofu state from GCP: `google_compute_network.vpc`/`google_project_service.compute` had to be re-imported (subnet was already saved), and `google_container_cluster.primary` couldn't be imported at all because GKE still held it in an active `CREATE_CLUSTER` operation. Separately, the agent had also read cached checkpoint text claiming the VPC's secondary range names were `pods`/`services` and edited `gke.tf` to match, without checking the range names actually on disk in `vpc.tf` (`gke-pods`/`gke-services`) — breaking the cluster's network references. The agent additionally mutated the read-only `thump` chart (`deploy/chart/thump/values.yaml`) directly instead of overriding at deploy time; this was reverted (`git reset --hard HEAD~2` in that repo, confirmed clean).
- **Resolution (Claude session)**: By the time this session started, the `CREATE_CLUSTER` operation had actually finished (not "still running" as the handover claimed) — the range-name mismatch was also already resolved on disk. The real fault: the cluster's default node pool hit `GCE_STOCKOUT` for `e2-standard-4` in `us-central1-c` (zones `a`/`b` succeeded), leaving the cluster in GCP status `ERROR`, orphaned from Tofu state. Deleted the orphaned cluster via `gcloud container clusters delete`, added `node_locations = ["us-central1-a", "us-central1-b", "us-central1-f"]` to `google_container_cluster.primary` in `gke.tf` to steer future node pools away from the stocked-out zone while preserving the 3-node topology assumed by the topology catalog, then re-ran `tofu apply` from a clean plan (10 to add, 0 to destroy — VPC/subnet were untouched throughout). Also fixed `README.md`/`CLAUDE.md`, which still described the retired live-Sloth-controller and `storage-class-raw.yaml` workflows.

