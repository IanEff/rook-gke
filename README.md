# Rook-Ceph GKE Infrastructure Provisioning

Machine-generated throwaway GCloud testbed for Kubernetes projects that need Rook-Ceph stats.  

Everything below this line has been inferred.

---

This repository contains the OpenTofu (Terraform) scripts and Kubernetes manifests to provision a regional Google Kubernetes Engine (GKE) cluster configured specifically to run a Rook-Ceph storage cluster. This environment is designed to test the companion reliability engine (`thump`).

## Features & Constraints Satisfied

1. **Kernel Module Compatibility**: Configures the GKE node pool to run Ubuntu (`UBUNTU_CONTAINERD` image type) instead of Container-Optimized OS (COS) so that nodes have out-of-the-box support for the `rbd` kernel modules required by Ceph.
2. **Raw Block Storage**: Provides a Kubernetes `StorageClass` via Terraform using GKE's CSI persistent disk driver (`pd.csi.storage.gke.io`) paired with a Rook OSD volume claim template requesting raw block devices (`volumeMode: Block`).
3. **Custom Network Topology**: Provisions a dedicated custom VPC and subnet with secondary ranges dedicated to GKE pods (`10.1.0.0/16`) and services (`10.2.0.0/20`), including required internal pod-to-pod firewall rules.
4. **Automated Helm Deployments**: Automates the deployment of the `rook-ceph` operator, `rook-ceph-cluster`, and `kube-prometheus-stack` directly through Terraform's Helm provider.
5. **Telemetry & Service Level Objectives**: Prometheus-backed SLOs for Ceph health and RGW availability, generated at build time with `sloth` (see `scripts/gen_slos.sh`) into a plain `PrometheusRule` the Prometheus Operator consumes — no live Sloth controller in the cluster.
6. **rbd Kernel Module Preload**: GKE's current `UBUNTU_CONTAINERD` image ships `rbd.ko` zstd-compressed; a small DaemonSet (`rbd-module-loader.tf`) preloads it via the host's own `kmod` on every node so cephcsi never has to `modprobe` it itself (see [Known GKE Gotchas](#known-gke-gotchas)).

---

## File Structure

- **[providers.tf](providers.tf)**: Configures the Google Cloud, Kubernetes, and Helm providers.
- **[variables.tf](variables.tf)**: Declares configuration options including defaults for GCP Project ID (`terraform-sandbox-430820`) and billing account.
- **[vpc.tf](vpc.tf)**: Provisions the custom VPC, subnetwork, secondary IP ranges, and internal firewall rules.
- **[gke.tf](gke.tf)**: Enables the GKE API, provisions the regional GKE cluster, and defines the Ubuntu node pool (`e2-standard-4` machines, 1 node per zone across 3 zones).
- **[rook.tf](rook.tf)**: Manages the Rook namespace, storage class, and installs the Rook operator and Ceph cluster via Helm.
- **[rbd-module-loader.tf](rbd-module-loader.tf)**: DaemonSet that preloads the `rbd` kernel module on every node via the host's own `modprobe` (see [Known GKE Gotchas](#known-gke-gotchas)).
- **[telemetry.tf](telemetry.tf)**: Installs the `kube-prometheus-stack` and `sloth` via Helm, and manages the Ceph topology catalog ConfigMap.
- **[loki.tf](loki.tf)**: Installs Loki + Promtail via Helm — log storage feeding thump's `loki` evidence tool.
- **[tempo.tf](tempo.tf)**: Installs Tempo via Helm — trace storage for thump's own self-observability (Phase B).
- **[outputs.tf](outputs.tf)**: Outputs the cluster name and the helper command to fetch credentials.
- **[justfile](justfile)**: Wraps the OpenTofu/kubectl lifecycle (`init`/`plan`/`apply`/`destroy`/`credentials`/`gen-slos`) so every recipe reinitializes providers first.
- **[k8s/sloth/prometheusservicelevels.yaml](k8s/sloth/prometheusservicelevels.yaml)**: Sloth `PrometheusServiceLevel` source spec (input to `gen_slos.sh`, not applied to the cluster directly).
- **[k8s/sloth/prometheus-rules.yaml](k8s/sloth/prometheus-rules.yaml)**: Generated `PrometheusRule` (build artifact — regenerate with `scripts/gen_slos.sh`, don't hand-edit).
- **[scripts/gen_slos.sh](scripts/gen_slos.sh)**: Runs `sloth generate` against the spec above and writes the `PrometheusRule`.
- **[k8s/topology-catalog/catalog-info.yaml](k8s/topology-catalog/catalog-info.yaml)**: Backstage/topology component definitions for Ceph.
- **[k8s/topology-catalog/state-queries.yaml](k8s/topology-catalog/state-queries.yaml)**: Maps each `catalog-info.yaml` dependency to the PromQL query that determines its up/down state (consumed by the `whir` dependency resolver).
- *(Note: `rook-cluster-osds-snippet.yaml` exists for historical reference but is actively managed by `rook.tf` in modern deployments)*.

---

## Getting Started

A `justfile` wraps the commands below (`just` alone lists recipes). Every recipe that
touches OpenTofu depends on `init`, so a missing or stale `.terraform/` (fresh clone,
pruned cache — it's gitignored and never survives either) can't cause a partial run
anymore; see [Recovering from a stuck teardown](#recovering-from-a-stuck-teardown) for
why that matters.

### Quickest path: `just up`
Provisions everything (VPC, GKE cluster, node pool, Rook-Ceph, Telemetry stack) and leaves
`kubectl` working in your *own* shell afterward, not just inside `just` recipes:
```bash
just up
```
It still stops for the interactive `yes` that `tofu apply` normally asks for — it's
creating real, billed cloud resources, so that confirmation isn't skipped. It's
equivalent to `just apply` + `just credentials` below, run back to back.

### Step by step
If you'd rather run each stage yourself:

#### 1. Initialize & Plan OpenTofu
Initialize the working directory (downloads providers for Google, Kubernetes, and Helm) and review the planned infrastructure changes:
```bash
just init
just plan
```

#### 2. Deploy Infrastructure
Deploy the VPC, subnet, GKE cluster, node pools, Rook-Ceph cluster, and Telemetry stack all in one go:
```bash
just apply
```

#### 3. Configure kubectl Credentials
Retrieve the credentials for the newly created cluster. This also symlinks
`gke-gcloud-auth-plugin` onto your shell's `PATH` if it isn't already
reachable there (see [Known GKE Gotchas](#known-gke-gotchas)) — without it,
`kubectl` fails with `exec: executable gke-gcloud-auth-plugin not found` even
though `tofu apply` itself succeeded:
```bash
just credentials
```

#### 4. Generate & Apply Sloth SLOs
SLOs are generated at build time (no live Sloth controller in the cluster). Regenerate the `PrometheusRule` from the spec and apply it so `kube-prometheus-stack`'s Prometheus Operator picks it up:
```bash
just gen-slos   # requires the `sloth` CLI
```

### Teardown Infrastructure
To completely tear down the GKE cluster, network, and all Ceph/Rook resources as quickly as the API allows, run:
```bash
just destroy
```
This always reinitializes providers first (`init` is a dependency), so it either fully
runs or never starts — it can't strand a half-deleted Rook namespace the way a bare
`tofu destroy` against a missing `.terraform/` can (see below).

### Recovering from a stuck teardown
If a `tofu destroy` is ever interrupted or fails partway through (as happened on
2026-07-08 from a missing `.terraform/`, before `just destroy` existed), Kubernetes may
delete the Rook operator before the `CephCluster`/`CephObjectStore` custom resources it
owns finish finalizing — and since the operator is what clears those finalizers, the
`rook-ceph` namespace is left `Terminating` forever with nothing left to unblock it.
Recognize it via:
```bash
kubectl get ns rook-ceph                       # stuck in Terminating
kubectl get ns rook-ceph -o jsonpath='{.status.conditions}'   # names the stuck finalizers
```
Fix by clearing the finalizers by hand (safe here — the operator and all Ceph daemons
are already gone, there's nothing live to corrupt) on whatever the conditions list, e.g.:
```bash
kubectl -n rook-ceph patch cephcluster rook-ceph --type=merge -p '{"metadata":{"finalizers":[]}}'
kubectl -n rook-ceph patch cephobjectstore <name> --type=merge -p '{"metadata":{"finalizers":[]}}'
kubectl -n rook-ceph patch configmap rook-ceph-mon-endpoints --type=merge -p '{"metadata":{"finalizers":[]}}'
kubectl -n rook-ceph patch secret rook-ceph-mon --type=merge -p '{"metadata":{"finalizers":[]}}'
```
Then re-run `just apply` for a clean rebuild. This is a hand-patch of an *already-dead*
namespace with no running daemons, not the live-cluster surgery `CLAUDE.md` warns
against — that policy is about not hand-patching a **running** Ceph cluster.

### Emergency teardown: `just pull-ripcord`
For when `just destroy` itself can't run — a corrupted `.terraform/`, an unresponsive
cluster API, or anything else that leaves OpenTofu unable to reach the cluster to tear it
down through the normal provider path:
```bash
just pull-ripcord
```
This bypasses OpenTofu entirely and drives `gcloud` directly (`scripts/ripcord.sh`):
deletes the GKE cluster, sweeps any orphaned PVC-backed persistent disks (deleting the
cluster this way skips Kubernetes' normal PVC-delete flow, which is what would otherwise
reclaim Rook OSD/mon, Loki, and Tempo disks), then the firewall rule, subnet, and VPC.
Every deletion is independently re-verified by listing the resource afterward rather than
trusting the delete call's exit code, and it prints a clear `[ok]`/`[FAIL]` summary. On a
fully clean teardown it also clears the now-stale local `terraform.tfstate`, since it no
longer describes anything real. Safe to re-run — every step is a no-op if already gone.

---

## Known GKE Gotchas

Deploying vanilla `rook-ceph` v1.14.7 onto GKE surfaced five independent, non-obvious
incompatibilities. Each is already fixed in this repo's `.tf` files — documented here so
nobody "fixes" them back to the chart defaults, and so the next incompatibility is easier
to recognize as the same *class* of problem.

1. **GKE rejects Rook's default priority classes.** The chart defaults mon/osd/mgr/mds and
   the CSI plugin/provisioner pods to `system-node-critical`/`system-cluster-critical`. GKE's
   `warden` admission webhook reserves those for GKE-managed namespaces only and rejects them
   outright elsewhere (`insufficient quota to match these scopes`). Fixed by overriding to
   `""` in three separate places: `cephClusterSpec.priorityClassNames` (mon/osd/mgr),
   `csi.pluginPriorityClassName`/`csi.provisionerPriorityClassName` on the *operator* chart,
   and — this one's easy to miss — `cephFileSystems[].spec.metadataServer.priorityClassName`
   for MDS, which lives on a completely different part of the values tree and does **not**
   read from `cephClusterSpec.priorityClassNames.mds` (that key is silently accepted by the
   CRD's permissive schema and never consulted).
2. **`rbd.ko` is zstd-compressed on current GKE images.** `UBUNTU_CONTAINERD` (Ubuntu 24.04,
   kernel 6.8) ships the module compressed; cephcsi's bundled `modprobe`/`kmod` can't
   decompress it (`Exec format error`). The host's own `kmod` (+ZSTD) loads it fine —
   `rbd-module-loader.tf` preloads it that way on every node before cephcsi ever tries.
3. **Monitoring RBAC needs a flag on the *operator* chart, not just the cluster chart.**
   `cephClusterSpec.monitoring.enabled=true` makes Rook try to create `ServiceMonitor`s, but
   the RBAC to do so is a separate `monitoring.enabled=true` on the `rook-ceph` operator
   chart. Without it, `ceph-cluster-controller`'s reconcile fails at "enable mgr services"
   on every attempt and never reaches OSD provisioning — with no obvious error surfaced
   anywhere except the operator's own logs.
4. **OSD device sets have no anti-affinity by default.** Nothing stops all N OSDs' PVCs (and
   therefore pods) from landing on the same node/zone — first-come-first-served on whichever
   node the prepare job schedules to. `rook.tf`'s `storageClassDeviceSets` has explicit
   `placement`/`preparePlacement` podAntiAffinity to spread one OSD per node, the same way
   Rook already does for mons.
5. **The chart's default resource requests are sized for real hardware, not a 3-node lab.**
   1 CPU per OSD (plus mon/mgr/mds defaults) saturates `e2-standard-4` nodes once GKE's own
   DaemonSets are accounted for. Trimmed in `rook.tf`'s `resources`/`metadataServer.resources`
   blocks — this is a low-traffic test cluster for `thump`, not a performance benchmark.
6. **`gke-gcloud-auth-plugin` is rarely on `PATH` by default.** Both `tofu apply`/`destroy`
   (via the kubernetes/helm providers' `exec` auth in `providers.tf`) and plain `kubectl`
   need this plugin, but `gcloud components install` drops it under the SDK's own `bin/`,
   which neither Homebrew's gcloud cask nor `gcloud` itself symlinks anywhere that's on
   `PATH` (and fish never sources gcloud's bash/zsh `path.*.inc` snippets). Left unfixed,
   `tofu apply` can run for 10+ minutes creating the cluster and node pool successfully,
   then fail with `exec: executable gke-gcloud-auth-plugin not found` once it reaches the
   kubernetes/helm resources. The `justfile` prepends the SDK's `bin/` dir to `PATH` for
   every recipe (fixes `tofu`), and `just credentials`/`just up` additionally run
   `scripts/link_auth_plugin.sh`, which symlinks the plugin into the same directory
   `gcloud` itself resolves from on your *actual* shell PATH (fixes bare `kubectl`).

**Operational note:** if the live cluster ever gets into a broken state, fix the root cause
in the `.tf` files and recover via `tofu destroy` (scoped with `-target` to the broken layer)
+ `tofu apply` — don't hand-patch the running cluster with `kubectl delete`/`ceph
--admin-daemon` surgery as a permanent fix. A corrupted Ceph mon store (from exactly that
kind of live surgery) is what necessitated the full Ceph-layer rebuild this repo's
`_system/log.md` documents for 2026-07-08.

---

## Generating S3 Traffic

To simulate S3 client workloads, you can deploy the included traffic generator which automatically provisions an `ObjectBucketClaim` and writes/deletes objects in a loop.

### 1. Deploy the Traffic Generator
Apply the Kubernetes manifest to create the bucket claim and the generator pod:
```bash
kubectl apply -f k8s/s3-traffic-generator.yaml
```

### 2. Start the Traffic
The pod will wait for manual activation before generating traffic. Exec into the pod and run the start script in the background:
```bash
kubectl exec -it deployment/s3-traffic-generator -- /start-traffic.sh
```

### 3. Scaling the Load
To increase the S3 load, scale the deployment to spin up multiple generator pods:
```bash
kubectl scale deployment s3-traffic-generator --replicas=5
```
Because the pods wait for manual activation, you'll need to start the script on all running pods. You can do this with a quick shell loop:
```bash
for pod in $(kubectl get pods -l app=s3-traffic-generator -o jsonpath='{.items[*].metadata.name}'); do
  kubectl exec -d $pod -- sh -c 'nohup /start-traffic.sh > /dev/null 2>&1 &'
done
```

---

## Generating Chaos for Signal Events

To test `thump` and validate your telemetry stack, you can introduce intentional chaos to trigger the defined Sloth SLO violations:

### 1. Triggering Ceph Health Violations (ceph-health)
The `ceph-health` SLO monitors the overall Ceph cluster health (WARN/ERR states).
- **Action**: Randomly kill Ceph Monitor or OSD pods.
  ```bash
  kubectl -n rook-ceph delete pod -l app=rook-ceph-osd
  kubectl -n rook-ceph delete pod -l app=rook-ceph-mon
  ```
- **Expected Signal**: Ceph will go into `HEALTH_WARN` (and possibly `HEALTH_ERR`) while it re-peers and backfills. The Sloth error ratio will immediately spike.

### 2. Triggering RGW Availability Violations (ceph-rgw-availability)
The `ceph-rgw-availability` SLO requires 99.9% of requests to succeed.
- **Action**: First, generate baseline traffic to the Rados Gateway (RGW). Then, forcefully terminate RGW pods or block their ports.
  ```bash
  # Example: forcefully terminate RGW pods while traffic is flowing
  kubectl -n rook-ceph delete pod -l app=rook-ceph-rgw --force --grace-period=0
  ```
- **Expected Signal**: Client requests will fail (5xx errors or timeouts), increasing the `ceph_rgw_failed_req` metric against `ceph_rgw_req`, which will trigger the availability SLO alert.
