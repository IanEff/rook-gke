# Remediate Rook-GKE Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Address initial design criticisms by adding missing VPC firewall rules, cleaning up Terraform filler, and porting the Rook/Telemetry stack from ceph-lab.

**Architecture:** We will manage the Kubernetes side (Rook, Prometheus, Sloth, Whir) via Terraform `helm_release` and `kubernetes_config_map` resources inside this repository to ensure the cluster is fully configured and ready for Thump upon `tofu apply`.

**Tech Stack:** OpenTofu, Kubernetes, Helm

## Global Constraints
- Do not mutate any data outside of the `rook-gke` repository.

---

### Task 1: Terraform Filler Cleanup

**Files:**
- Modify: `/Users/ian/projects/ceph/rook-gke/variables.tf:19-24`
- Modify: `/Users/ian/projects/ceph/rook-gke/gke.tf:53-57`
- Modify: `/Users/ian/projects/ceph/rook-gke/rook-cluster-osds-snippet.yaml:19-23`

**Interfaces:**
- Consumes: Existing generic Terraform templates
- Produces: Cleaned up terraform config without fake values

- [ ] **Step 1: Remove unused billing account variable**
Remove the `billing_account` variable block from `variables.tf`.

- [ ] **Step 2: Restrict OAuth scopes**
In `gke.tf`, inside `google_container_node_pool.primary_nodes`, change `oauth_scopes` from `["https://www.googleapis.com/auth/cloud-platform"]` to the minimal required scopes:
```hcl
    oauth_scopes = [
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
      "https://www.googleapis.com/auth/servicecontrol",
      "https://www.googleapis.com/auth/service.management.readonly",
      "https://www.googleapis.com/auth/trace.append"
    ]
```

- [ ] **Step 3: Remove fake taint from snippet**
In `rook-cluster-osds-snippet.yaml`, remove the `placement` block containing the `client.common.usr.id` toleration, leaving only the required `count` and `portable` parameters.

- [ ] **Step 4: Commit**
```bash
git add variables.tf gke.tf rook-cluster-osds-snippet.yaml
git commit -m "chore: clean up terraform filler and fake taint"
```

### Task 2: VPC Firewall Rules

**Files:**
- Modify: `/Users/ian/projects/ceph/rook-gke/vpc.tf`

**Interfaces:**
- Consumes: VPC network from `vpc.tf`
- Produces: Internal firewall rules for GKE

- [ ] **Step 1: Add firewall rule resource**
Add a new `google_compute_firewall` resource to the end of `vpc.tf` to allow all internal traffic (required for Ceph mon/mgr/OSD quorum).
```hcl
# Allow internal traffic within the VPC
resource "google_compute_firewall" "allow_internal" {
  name    = "${var.cluster_name}-allow-internal"
  network = google_compute_network.vpc.name
  project = var.project_id

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = [
    "10.0.0.0/20", # Nodes
    "10.1.0.0/16", # Pods
    "10.2.0.0/20"  # Services
  ]
}
```

- [ ] **Step 2: Commit**
```bash
git add vpc.tf
git commit -m "fix: add internal firewall rules for pod-to-pod communication"
```

### Task 3: Provider Setup for K8s & Helm

**Files:**
- Modify: `/Users/ian/projects/ceph/rook-gke/providers.tf`

**Interfaces:**
- Consumes: GKE cluster credentials
- Produces: Configured `helm` and `kubernetes` providers

- [ ] **Step 1: Add data sources and providers**
Append to `providers.tf`:
```hcl
data "google_client_config" "default" {}

provider "kubernetes" {
  host                   = "https://${google_container_cluster.primary.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(google_container_cluster.primary.master_auth[0].cluster_ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = "https://${google_container_cluster.primary.endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(google_container_cluster.primary.master_auth[0].cluster_ca_certificate)
  }
}
```

- [ ] **Step 2: Commit**
```bash
git add providers.tf
git commit -m "feat: configure kubernetes and helm providers"
```

### Task 4: Deploy Rook Operator & Cluster

**Files:**
- Create: `/Users/ian/projects/ceph/rook-gke/rook.tf`

**Interfaces:**
- Consumes: Helm provider
- Produces: Rook Ceph cluster

- [ ] **Step 1: Create rook.tf with Helm releases**
```hcl
resource "kubernetes_namespace" "rook_ceph" {
  metadata {
    name = "rook-ceph"
  }
  depends_on = [google_container_node_pool.primary_nodes]
}

resource "helm_release" "rook_ceph_operator" {
  name       = "rook-ceph"
  repository = "https://charts.rook.io/release"
  chart      = "rook-ceph"
  namespace  = kubernetes_namespace.rook_ceph.metadata[0].name
  version    = "v1.14.7"
  
  set {
    name  = "csi.enableRbdDriver"
    value = "true"
  }
}

resource "helm_release" "rook_ceph_cluster" {
  name       = "rook-ceph-cluster"
  repository = "https://charts.rook.io/release"
  chart      = "rook-ceph-cluster"
  namespace  = kubernetes_namespace.rook_ceph.metadata[0].name
  version    = "v1.14.7"
  
  depends_on = [helm_release.rook_ceph_operator]
  
  values = [
    <<EOF
cephClusterSpec:
  storage:
    useAllNodes: false
    useAllDevices: false
    storageClassDeviceSets:
    - name: rook-gke-osds
      count: 3
      portable: true
      volumeClaimTemplates:
      - metadata:
          name: data
        spec:
          resources:
            requests:
              storage: 100Gi
          storageClassName: rook-raw-block
          volumeMode: Block
          accessModes:
            - ReadWriteOnce
EOF
  ]
}
```

- [ ] **Step 2: Commit**
```bash
git add rook.tf
git commit -m "feat: deploy rook operator and cluster via helm"
```

### Task 5: Deploy Telemetry Stack (Prometheus, Sloth, Whir)

**Files:**
- Create: `/Users/ian/projects/ceph/rook-gke/k8s/topology-catalog/catalog-info.yaml`
- Create: `/Users/ian/projects/ceph/rook-gke/telemetry.tf`

**Interfaces:**
- Consumes: Topology catalog from ceph-lab
- Produces: Telemetry stack deployed via Helm and Kubernetes resources

- [ ] **Step 1: Copy whir catalog from ceph-lab**
```bash
mkdir -p /Users/ian/projects/ceph/rook-gke/k8s/topology-catalog
cp /Users/ian/projects/ceph/ceph-lab/applications/infrastructure/topology-catalog/catalog-info.yaml /Users/ian/projects/ceph/rook-gke/k8s/topology-catalog/catalog-info.yaml
```

- [ ] **Step 2: Create telemetry.tf**
```hcl
resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
  }
  depends_on = [google_container_node_pool.primary_nodes]
}

resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  version    = "61.3.0"

  set {
    name  = "prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues"
    value = "false"
  }
}

resource "helm_release" "sloth" {
  name       = "sloth"
  repository = "https://slok.github.io/sloth"
  chart      = "sloth"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  version    = "0.10.0"
  
  depends_on = [helm_release.kube_prometheus_stack]
}

resource "kubernetes_config_map" "ceph_topology_catalog" {
  metadata {
    name      = "ceph-topology-catalog"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    "catalog-info.yaml" = file("${path.module}/k8s/topology-catalog/catalog-info.yaml")
  }
}
```

- [ ] **Step 3: Commit**
```bash
git add telemetry.tf k8s/
git commit -m "feat: deploy telemetry stack (prometheus, sloth, whir catalog)"
```
