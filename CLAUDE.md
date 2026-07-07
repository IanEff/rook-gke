# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

OpenTofu (Terraform) configuration and Kubernetes manifests that provision a regional GKE cluster purpose-built to run Rook-Ceph. This is a test environment for the companion reliability engine `thump` (not part of this repo).

## Commands

This repo uses **OpenTofu**, not Terraform (`tofu`, not `terraform`).

```bash
tofu init      # initialize providers/backend
tofu validate  # syntax/config check
tofu plan      # preview changes
tofu apply     # provision VPC + GKE cluster + node pool
tofu destroy   # tear down
```

After `apply`, fetch cluster credentials (command also emitted via the `get_credentials_command` output):
```bash
gcloud container clusters get-credentials rook-ceph-gke --region us-central1 --project terraform-sandbox-430820
```

Kubernetes manifests are applied separately, after the cluster exists:
```bash
kubectl apply -f storage-class-raw.yaml
```
`rook-cluster-osds-snippet.yaml` is not applied directly — it's a YAML fragment meant to be merged into an external Rook `CephCluster` CR under `spec.storage` (that CR lives outside this repo, wherever Rook is installed).

There is no test suite, linter, or CI config in this repo; `tofu validate`/`tofu plan` is the correctness check.

## Architecture

Three concerns, each satisfying a specific Ceph-on-GKE constraint (see README for full rationale):

1. **Networking (`vpc.tf`)** — custom VPC + subnet (not GKE auto-mode) with dedicated secondary ranges for pods (`10.1.0.0/16`) and services (`10.2.0.0/20`), so IP allocation is explicit and predictable.
2. **Compute (`gke.tf`)** — regional GKE cluster with the default node pool removed and replaced by an explicit node pool. The node pool **must** use `image_type = "UBUNTU_CONTAINERD"` rather than COS — this is the load-bearing decision in the whole config, since Ceph's `rbd` kernel module isn't available out-of-the-box on COS. Don't change this without checking the RBD requirement still holds.
3. **Storage (`storage-class-raw.yaml`, `rook-cluster-osds-snippet.yaml`)** — a `StorageClass` backed by `pd.csi.storage.gke.io`, paired with a Rook OSD volume claim template that requests `volumeMode: Block` (raw block device, not a filesystem-formatted PVC). `volumeMode` belongs on the PVC/claim template, not the StorageClass itself — see the comment at the top of `storage-class-raw.yaml` if tempted to add it there.

Resource naming is driven by `var.cluster_name` (default `rook-ceph-gke`); most resource names are `${var.cluster_name}-*`. Config defaults (`variables.tf`) target a specific sandbox project (`terraform-sandbox-430820`, `us-central1`) — treat these as environment-specific, not universal, defaults.

`outputs.tf` exposes `cluster_name` and a ready-to-run `get_credentials_command` string — prefer extending outputs here over hardcoding cluster details elsewhere.

## Notes

- `_system/log.md` is a running log of work done in this repo by prior agent sessions — check it for history/context before assuming something is undocumented.
- `.gitignore` excludes `.terraform/`, `*.tfstate*`, and `*.tfvars*` — never commit state files or tfvars (they may carry project-specific/sensitive values).
