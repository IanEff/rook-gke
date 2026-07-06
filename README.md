# Rook-Ceph GKE Infrastructure Provisioning

This repository contains the OpenTofu (Terraform) scripts and Kubernetes manifests to provision a regional Google Kubernetes Engine (GKE) cluster configured specifically to run a Rook-Ceph storage cluster. This environment is designed to test the companion reliability engine (`thump`).

## Features & Constraints Satisfied

1. **Kernel Module Compatibility**: Configures the GKE node pool to run Ubuntu (`UBUNTU_CONTAINERD` image type) instead of Container-Optimized OS (COS) so that nodes have out-of-the-box support for the `rbd` kernel modules required by Ceph.
2. **Raw Block Storage**: Provides a Kubernetes `StorageClass` manifest using GKE's CSI persistent disk driver (`pd.csi.storage.gke.io`) paired with a Rook OSD volume claim template requesting raw block devices (`volumeMode: Block`).
3. **Custom Network Topology**: Provisions a dedicated custom VPC and subnet with secondary ranges dedicated to GKE pods (`10.1.0.0/16`) and services (`10.2.0.0/20`).

---

## File Structure

- **[providers.tf](providers.tf)**: Configures the Google Cloud provider.
- **[variables.tf](variables.tf)**: Declares configuration options including defaults for GCP Project ID (`terraform-sandbox-430820`) and billing account.
- **[vpc.tf](vpc.tf)**: Provisions the custom VPC, subnetwork, secondary IP ranges, and enables the Google Compute Engine API.
- **[gke.tf](gke.tf)**: Enables the GKE API, provisions the regional GKE cluster, and defines the Ubuntu node pool (`e2-standard-4` machines, 1 node per zone across 3 zones).
- **[outputs.tf](outputs.tf)**: Outputs the cluster name and the helper command to fetch credentials.
- **[storage-class-raw.yaml](storage-class-raw.yaml)**: Kubernetes `StorageClass` using GKE persistent disks (`pd.csi.storage.gke.io`).
- **[rook-cluster-osds-snippet.yaml](rook-cluster-osds-snippet.yaml)**: Configuration snippet for the Rook `CephCluster` Custom Resource OSD `storageClassDeviceSets` section requesting raw block storage.

---

## Getting Started

### 1. Initialize & Plan OpenTofu
Initialize the working directory and review the planned infrastructure changes:
```bash
tofu init
tofu plan
```

### 2. Deploy Infrastructure
Deploy the VPC, subnet, GKE cluster, and node pools:
```bash
tofu apply
```

### 3. Configure kubectl Credentials
Retrieve the credentials for the newly created cluster:
```bash
gcloud container clusters get-credentials rook-ceph-gke --region us-central1 --project terraform-sandbox-430820
```

### 4. Create the StorageClass
Apply the StorageClass manifest to your cluster:
```bash
kubectl apply -f storage-class-raw.yaml
```

### 5. Deploy Rook-Ceph Cluster OSDs
Integrate the snippet from `rook-cluster-osds-snippet.yaml` into your Rook `CephCluster` Custom Resource (CRD) spec under `spec.storage` to dynamically allocate raw block devices for OSD storage.
