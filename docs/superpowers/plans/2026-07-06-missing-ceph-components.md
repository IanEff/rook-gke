# Missing Ceph Components Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `rook-raw-block` StorageClass and enable telemetry monitoring for the Rook Ceph cluster to complete the Thump infrastructure.

**Architecture:** We are augmenting existing OpenTofu definitions in `rook.tf` by adding a new `kubernetes_storage_class` resource and updating the Helm release values for the Ceph cluster.

**Tech Stack:** OpenTofu, Kubernetes (GKE CSI), Helm, Rook Ceph

## Global Constraints

- Do not mutate any data outside of the `rook-gke` repository.

---

### Task 1: Add StorageClass

**Files:**
- Modify: `rook.tf`

**Interfaces:**
- Produces: `kubernetes_storage_class.rook_raw_block`

- [ ] **Step 1: Add the StorageClass resource**

Append the following to `rook.tf`:

```hcl
resource "kubernetes_storage_class" "rook_raw_block" {
  metadata {
    name = "rook-raw-block"
  }
  storage_provisioner = "pd.csi.storage.gke.io"
  volume_binding_mode = "WaitForFirstConsumer"
  parameters = {
    type = "pd-standard"
  }
}
```

- [ ] **Step 2: Run validation to verify syntax**

Run: `tofu validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Format the code**

Run: `tofu fmt`

- [ ] **Step 4: Commit**

```bash
git add rook.tf
git commit -m "feat: add rook-raw-block StorageClass"
```

---

### Task 2: Optimize OSD Size

**Files:**
- Modify: `rook.tf`

**Interfaces:**
- Consumes: The `helm_release.rook_ceph_cluster` definition in `rook.tf`

- [ ] **Step 1: Update the OSD storage request**

Modify `rook.tf` to change the `storage` request in `helm_release.rook_ceph_cluster` from `100Gi` to `10Gi`:

```yaml
          resources:
            requests:
              storage: 10Gi
```

- [ ] **Step 2: Run validation to verify syntax**

Run: `tofu validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Commit**

```bash
git add rook.tf
git commit -m "chore: shrink OSD storage request for dev cost savings"
```

---

### Task 3: Enable Monitoring

**Files:**
- Modify: `rook.tf`

**Interfaces:**
- Consumes: The `helm_release.rook_ceph_cluster` definition in `rook.tf`

- [ ] **Step 1: Update the Ceph cluster values to enable monitoring**

Modify the `values` block in `helm_release.rook_ceph_cluster` in `rook.tf` to add the monitoring section under `cephClusterSpec`:

```yaml
cephClusterSpec:
  monitoring:
    enabled: true
    createPrometheusRules: true
  storage:
```

- [ ] **Step 2: Run validation to verify syntax**

Run: `tofu validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Commit**

```bash
git add rook.tf
git commit -m "feat: enable ceph cluster monitoring"
```
