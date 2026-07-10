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

`rook-cluster-osds-snippet.yaml` is not applied directly — it's a YAML fragment kept for historical reference; the OSD volume claim template it documents is now managed inline in `rook.tf`'s `helm_release.rook_ceph_cluster` values.

Sloth SLOs are generated at build time, not deployed via a live controller:
```bash
./scripts/gen_slos.sh   # requires the `sloth` CLI; regenerates k8s/sloth/prometheus-rules.yaml from k8s/sloth/prometheusservicelevels.yaml
kubectl apply -f k8s/sloth/prometheus-rules.yaml
```

There is no test suite, linter, or CI config in this repo; `tofu validate`/`tofu plan` is the correctness check.

## Architecture

Four concerns, each satisfying a specific Ceph-on-GKE constraint (see README for full rationale):

1. **Networking (`vpc.tf`)** — custom VPC + subnet (not GKE auto-mode) with dedicated secondary ranges for pods (`10.1.0.0/16`) and services (`10.2.0.0/20`), so IP allocation is explicit and predictable.
2. **Compute (`gke.tf`)** — regional GKE cluster with the default node pool removed and replaced by an explicit node pool. The node pool **must** use `image_type = "UBUNTU_CONTAINERD"` rather than COS — this is the load-bearing decision in the whole config, since Ceph's `rbd` kernel module isn't available out-of-the-box on COS. Don't change this without checking the RBD requirement still holds. `node_locations` is pinned to `["us-central1-a", "us-central1-b", "us-central1-f"]`, deliberately excluding `us-central1-c` after a `GCE_STOCKOUT` there for `e2-standard-4` — don't remove the pin without checking capacity in that zone first.
3. **Storage (`rook.tf`)** — a `kubernetes_storage_class` (`rook-raw-block`, backed by `pd.csi.storage.gke.io`, type `pd-balanced`), paired with a Rook OSD volume claim template (in `helm_release.rook_ceph_cluster`'s values) that requests `volumeMode: Block` (raw block device, not a filesystem-formatted PVC). `volumeMode` belongs on the PVC/claim template, not the StorageClass itself. (`storage-class-raw.yaml` was retired in favor of this Tofu-managed resource — don't recreate it.)
4. **rbd kernel module (`rbd-module-loader.tf`)** — a DaemonSet that preloads `rbd` via the host's own `kmod` on every node. GKE's current `UBUNTU_CONTAINERD` image ships `rbd.ko` zstd-compressed; cephcsi's bundled `modprobe` can't decompress it (`Exec format error`) even though `image_type` is correct. Don't remove this thinking the image-type fix alone is sufficient — it isn't, on current GKE images.

Resource naming is driven by `var.cluster_name` (default `rook-ceph-gke`); most resource names are `${var.cluster_name}-*`. Config defaults (`variables.tf`) target a specific sandbox project (`terraform-sandbox-430820`, `us-central1`) — treat these as environment-specific, not universal, defaults.

`outputs.tf` exposes `cluster_name` and a ready-to-run `get_credentials_command` string — prefer extending outputs here over hardcoding cluster details elsewhere.

### rook.tf gotchas (read before editing priority classes, resources, or MDS)

- **GKE's `warden` admission webhook rejects Rook's default `system-node-critical`/
  `system-cluster-critical` priority classes** outside GKE-managed namespaces. These are
  overridden to `""` in three *separate* places — don't assume fixing one covers the others:
  `cephClusterSpec.priorityClassNames` (mon/osd/mgr) in `helm_release.rook_ceph_cluster`,
  `csi.pluginPriorityClassName`/`csi.provisionerPriorityClassName` in
  `helm_release.rook_ceph_operator`, and `cephFileSystems[].spec.metadataServer.priorityClassName`
  for MDS. That last one is the trap: `cephClusterSpec.priorityClassNames.mds` looks like it
  should work (the CRD's permissive schema accepts it silently) but Rook's code never reads
  it — MDS's priority class and resources live on the CephFilesystem's own `metadataServer`,
  not the cluster-wide map.
- **`cephClusterSpec.monitoring.enabled` alone is not enough.** It needs a *separate*
  `monitoring.enabled=true` on the operator chart (`helm_release.rook_ceph_operator`) to grant
  the RBAC to create `ServiceMonitor`s. Without it, `ceph-cluster-controller` reconcile fails
  silently at "enable mgr services" on every attempt and OSD provisioning never starts.
- **`storageClassDeviceSets` needs explicit `placement`/`preparePlacement` podAntiAffinity.**
  Without it, nothing stops all OSDs landing on the same node/zone.
- **Resource requests are deliberately trimmed below the chart defaults** (mon/mgr/osd/mds) —
  this is a low-traffic test cluster for `thump`, not a performance benchmark, and the
  defaults saturate `e2-standard-4` nodes once GKE's own DaemonSets are accounted for. If you
  bump these back up, check node headroom (`kubectl describe nodes`) leaves room for `thump`.
- **Rook's file-controller (MDS) only applies `metadataServer` settings at Deployment
  *creation* time** — changing the CephFilesystem spec does not patch an already-existing MDS
  Deployment. If an MDS config change doesn't seem to take effect, check
  `kubectl get deployment rook-ceph-mds-<fs> -o jsonpath='{.metadata.generation}'`; if it's
  still `1`, delete the Deployment (safe if it never successfully ran a pod) to force clean
  recreation.

## Notes

- `_system/log.md` is a running log of work done in this repo by prior agent sessions — check it for history/context before assuming something is undocumented.
- `.gitignore` excludes `.terraform/`, `*.tfstate*`, and `*.tfvars*` — never commit state files or tfvars (they may carry project-specific/sensitive values).
- **If the live cluster breaks, fix the repo and rebuild — don't hand-patch the running cluster.** Recover via `tofu destroy` (scoped with `-target` to the broken layer) + `tofu apply`, after fixing the root cause in the relevant `.tf` file. This is a disposable test environment with no production data, so destroy+rebuild is cheap relative to the risk of live `kubectl`/`ceph --admin-daemon` surgery leaving a stateful system (especially Ceph mons) in a worse, inconsistent state. A corrupted mon store from exactly that kind of live surgery is what necessitated a full Ceph-layer rebuild — see `_system/log.md`'s 2026-07-08 entry.
- **`tofu apply`/`destroy` can fail late with `exec: executable gke-gcloud-auth-plugin not found`** (after the cluster/node pool already finished creating) if that plugin isn't on `PATH` — `gcloud components install` puts it under the SDK's own `bin/`, but nothing symlinks it into `/opt/homebrew/bin` or similar, and fish never sources gcloud's bash/zsh `path.*.inc` snippets. `just apply`/`just destroy` etc. prepend the SDK's `bin/` dir to `PATH` for exactly this reason (see `justfile`); if invoking `tofu` directly, make sure `gke-gcloud-auth-plugin` resolves on `PATH` first (`gcloud info --format='value(installation.sdk_root)')/bin`).
  That justfile-level `PATH` export only covers processes `just` itself launches, though — it can't fix a bare `kubectl` run afterward in your own shell, which execs the same plugin using your shell's actual `PATH`. `just credentials`/`just up` additionally run `scripts/link_auth_plugin.sh`, which symlinks the plugin into whatever directory `gcloud` itself resolves from on your real shell `PATH` (e.g. Homebrew's `gcloud` symlink dir) — that script deliberately strips the SDK's `bin/` dir back out of `PATH` before doing that lookup, since inside a `just` recipe it'd otherwise resolve `gcloud` to the SDK's own `bin/` (the one just prepended) and treat that as the target, silently no-op'ing.
