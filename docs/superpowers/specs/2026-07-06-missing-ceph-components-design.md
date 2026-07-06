# Missing Ceph Components Design

## Purpose
The Rook/Ceph infrastructure in `rook-gke` is missing a StorageClass for the Ceph OSDs and the monitoring configurations required for telemetry (e.g., `ServiceMonitor`s for `thump`). This design outlines the addition of these missing components while optimizing for the absolute lowest cost dev environment.

## 1. StorageClass Configuration
A `kubernetes_storage_class` resource named `rook-raw-block` will be added to `rook.tf`.
- **Provisioner:** `pd.csi.storage.gke.io`
- **Type:** `pd-standard` (cheapest GCP block storage, backed by HDD).
- **Volume Binding Mode:** `WaitForFirstConsumer` (ensures disks are provisioned in the correct zone where the OSD pod is scheduled).

## 2. Cost Optimization for OSDs
To minimize costs for this dev cluster, the `rook-ceph-cluster` Helm values in `rook.tf` will be updated:
- **Storage Request:** Reduce from `100Gi` to `10Gi` (the minimum viable size for Ceph OSDs to format and run).
- **Count:** Kept at `3` (one per node) to maintain a minimal healthy Ceph quorum.

## 3. Monitoring Configuration
The `rook-ceph-cluster` Helm values in `rook.tf` will be updated to explicitly enable monitoring:
```yaml
monitoring:
  enabled: true
  createPrometheusRules: true
```
This configuration instructs the Rook operator to automatically generate the required `ServiceMonitor` and `PrometheusRule` resources for the Ceph Mgr and Ceph Exporter components.
