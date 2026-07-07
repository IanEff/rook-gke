# Rook-Ceph GKE Infrastructure Provisioning

This repository contains the OpenTofu (Terraform) scripts and Kubernetes manifests to provision a regional Google Kubernetes Engine (GKE) cluster configured specifically to run a Rook-Ceph storage cluster. This environment is designed to test the companion reliability engine (`thump`).

## Features & Constraints Satisfied

1. **Kernel Module Compatibility**: Configures the GKE node pool to run Ubuntu (`UBUNTU_CONTAINERD` image type) instead of Container-Optimized OS (COS) so that nodes have out-of-the-box support for the `rbd` kernel modules required by Ceph.
2. **Raw Block Storage**: Provides a Kubernetes `StorageClass` via Terraform using GKE's CSI persistent disk driver (`pd.csi.storage.gke.io`) paired with a Rook OSD volume claim template requesting raw block devices (`volumeMode: Block`).
3. **Custom Network Topology**: Provisions a dedicated custom VPC and subnet with secondary ranges dedicated to GKE pods (`10.1.0.0/16`) and services (`10.2.0.0/20`), including required internal pod-to-pod firewall rules.
4. **Automated Helm Deployments**: Automates the deployment of the `rook-ceph` operator, `rook-ceph-cluster`, `kube-prometheus-stack`, and `sloth` directly through Terraform's Helm provider.
5. **Telemetry & Service Level Objectives**: Fully integrated monitoring stack featuring Prometheus and Sloth for evaluating Service Level Objectives (SLOs) around Ceph latency, health, and availability.

---

## File Structure

- **[providers.tf](providers.tf)**: Configures the Google Cloud, Kubernetes, and Helm providers.
- **[variables.tf](variables.tf)**: Declares configuration options including defaults for GCP Project ID (`terraform-sandbox-430820`) and billing account.
- **[vpc.tf](vpc.tf)**: Provisions the custom VPC, subnetwork, secondary IP ranges, and internal firewall rules.
- **[gke.tf](gke.tf)**: Enables the GKE API, provisions the regional GKE cluster, and defines the Ubuntu node pool (`e2-standard-4` machines, 1 node per zone across 3 zones).
- **[rook.tf](rook.tf)**: Manages the Rook namespace, storage class, and installs the Rook operator and Ceph cluster via Helm.
- **[telemetry.tf](telemetry.tf)**: Installs the `kube-prometheus-stack` and `sloth` via Helm, and manages the Ceph topology catalog ConfigMap.
- **[outputs.tf](outputs.tf)**: Outputs the cluster name and the helper command to fetch credentials.
- **[k8s/sloth/prometheusservicelevels.yaml](k8s/sloth/prometheusservicelevels.yaml)**: Sloth `PrometheusServiceLevel` custom resources defining SLOs for the cluster.
- **[k8s/topology-catalog/catalog-info.yaml](k8s/topology-catalog/catalog-info.yaml)**: Backstage/topology component definitions for Ceph.
- *(Note: `rook-cluster-osds-snippet.yaml` exists for historical reference but is actively managed by `rook.tf` in modern deployments)*.

---

## Getting Started

### 1. Initialize & Plan OpenTofu
Initialize the working directory (downloads providers for Google, Kubernetes, and Helm) and review the planned infrastructure changes:
```bash
tofu init
tofu plan
```

### 2. Deploy Infrastructure
Deploy the VPC, subnet, GKE cluster, node pools, Rook-Ceph cluster, and Telemetry stack all in one go:
```bash
tofu apply
```

### 3. Configure kubectl Credentials
Retrieve the credentials for the newly created cluster:
```bash
gcloud container clusters get-credentials rook-ceph-gke --region us-central1 --project terraform-sandbox-430820
```

### 4. Deploy Sloth SLOs
With the cluster and telemetry stack deployed, apply the `PrometheusServiceLevel` CRDs so the Sloth controller begins evaluating Ceph and ArgoCD SLOs:
```bash
kubectl apply -f k8s/sloth/prometheusservicelevels.yaml
```

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

### 2. Triggering OSD Latency Violations (ceph-osd-latency)
The `ceph-osd-latency` SLO requires 99% of OSD writes to complete in <100ms.
- **Action**: Introduce network latency between pods using [Chaos Mesh](https://chaos-mesh.org/) or raw `tc` commands on the nodes, OR overwhelm the disk IO with a massive `fio` write workload.
- **Expected Signal**: `ceph_osd_op_w_latency_bucket` times will shift, burning through your latency error budget in Sloth.

### 3. Triggering RGW Availability Violations (ceph-rgw-availability)
The `ceph-rgw-availability` SLO requires 99.9% of requests to succeed.
- **Action**: First, generate baseline traffic to the Rados Gateway (RGW). Then, forcefully terminate RGW pods or block their ports.
  ```bash
  # Example: forcefully terminate RGW pods while traffic is flowing
  kubectl -n rook-ceph delete pod -l app=rook-ceph-rgw --force --grace-period=0
  ```
- **Expected Signal**: Client requests will fail (5xx errors or timeouts), increasing the `ceph_rgw_failed_req` metric against `ceph_rgw_req`, which will trigger the availability SLO alert.

### 4. Triggering ArgoCD Sync Violations (argocd-sync)
- **Action**: Manually modify a deployed resource in the cluster (e.g., scale a deployment) directly via `kubectl` without committing it to git, causing ArgoCD to report an `OutOfSync` state.
- **Expected Signal**: Sloth will register a violation for `argocd-sync` until the resource is either synced back by ArgoCD or fixed in the repository.
