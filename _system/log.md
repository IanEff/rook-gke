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

