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
- *(Note: `storage-class-raw.yaml` and `rook-cluster-osds-snippet.yaml` exist for historical reference but are actively managed by `rook.tf` in modern deployments)*.

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
