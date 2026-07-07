# Rook-GKE Telemetry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Configure rook-gke with the specified telemetry design (clean GKE SLI/SLO baseline) to support thump's metrics engine, and execute infra reconciliation.

**Architecture:** Port ceph-lab's SLO model over to rook-gke (using sloth generate at build time, no live controller), wire operator ServiceMonitor scraping, clean up catalog/storage class topology, and ensure thump can reach it.

**Tech Stack:** Terraform, Kubernetes, Prometheus Operator, Sloth.

## Global Constraints

- Must run exactly as Ian specified in `rook-gke-telemetry-design.md` (overriding the rule that agents don't apply infra).
- Off-Ceph stores for thump must use a GCE PD class (`standard` / `pd-standard`).

---

### Task 1: Reconcile StorageClass and Clean up Topology

**Files:**
- Modify: `rook.tf`
- Modify: `README.md`
- Delete: `storage-class-raw.yaml`

**Interfaces:**
- Consumes: N/A
- Produces: Correct block storage topology.

- [ ] **Step 1: Delete duplicate StorageClass**
  Run: `rm storage-class-raw.yaml`

- [ ] **Step 2: Update rook.tf StorageClass type**
  Change `pd-standard` to `pd-balanced` in `rook_raw_block`.

- [ ] **Step 3: Clean up README references to storage-class-raw.yaml**
  Remove the reference from `README.md`.

- [ ] **Step 4: Commit**
  Run: `git commit -am "chore: reconcile StorageClass defs to pd-balanced"`

### Task 2: Rewrite Topology Catalog for GKE

**Files:**
- Modify: `k8s/topology-catalog/catalog-info.yaml`

**Interfaces:**
- Consumes: GKE deployment model
- Produces: Correct component topology for thump

- [ ] **Step 1: Replace ceph-lab entities**
  Drop argocd, cilium, cephfs. Update nodes to generic names (e.g., `gke-node-1`, `gke-node-2`, `gke-node-3`) and update disks to pd-csi instead of `/dev/vdc`.

- [ ] **Step 2: Commit**
  Run: `git commit -am "feat: rewrite topology catalog for GKE nodes"`

### Task 3: Author state-queries.yaml

**Files:**
- Create: `k8s/topology-catalog/state-queries.yaml`

**Interfaces:**
- Consumes: catalog-info.yaml
- Produces: PromQL rules mapping dependencies to status.

- [ ] **Step 1: Write state-queries.yaml**
  Create simple PromQL queries representing the up-state of components.

- [ ] **Step 2: Commit**
  Run: `git add k8s/topology-catalog/state-queries.yaml && git commit -m "feat: author state-queries.yaml"`

### Task 4: SLO Source + Gen-SLOs

**Files:**
- Modify: `k8s/sloth/prometheusservicelevels.yaml`
- Modify: `telemetry.tf`
- Create: `scripts/gen_slos.sh`

**Interfaces:**
- Consumes: SLI requirements
- Produces: Operator-compatible `PrometheusRule` objects.

- [ ] **Step 1: Trim prometheusservicelevels.yaml**
  Keep only `ceph-health` and `ceph-rgw-availability`.

- [ ] **Step 2: Retire live Sloth**
  Remove `helm_release "sloth"` from `telemetry.tf`.

- [ ] **Step 3: Create build-time gen script**
  Create a script to generate Prom rules and output to `k8s/sloth/prometheus-rules.yaml`. Add `release: kube-prometheus-stack` label.

- [ ] **Step 4: Run script and commit**
  Run script, `git add k8s/sloth`, `git commit -m "feat: port sloth model to build-time"`.

### Task 5: Wire Prometheus URL and Off-Ceph Stores

**Files:**
- Modify: `~/projects/go/thump/deploy/chart/thump/values.yaml`

**Interfaces:**
- Consumes: GKE Prometheus service
- Produces: Thump configuration

- [ ] **Step 1: Edit values.yaml**
  Set `prometheus.url` to `http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090`
  Set `storageClass` for NATS and s3mock to `standard`.

- [ ] **Step 2: Commit**
  Run: `git commit -am "feat: configure prometheus URL and off-ceph stores for rook-gke"`

### Task 6: Tofu Apply Cluster

**Files:** N/A

**Interfaces:**
- Consumes: Terraform config
- Produces: Running cluster

- [ ] **Step 1: Tofu Init & Apply**
  Run `tofu init` and `tofu apply -auto-approve` to provision the cluster.
