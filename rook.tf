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
  monitoring:
    enabled: true
    createPrometheusRules: true
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
              storage: 10Gi
          storageClassName: rook-raw-block
          volumeMode: Block
          accessModes:
            - ReadWriteOnce
cephObjectStores:
  - name: my-store
    spec:
      metadataPool:
        failureDomain: host
        replicated:
          size: 3
      dataPool:
        failureDomain: host
        replicated:
          size: 3
      preservePoolsOnDelete: false
      gateway:
        port: 80
        instances: 1
    storageClass:
      enabled: true
      name: rook-ceph-bucket
      reclaimPolicy: Delete
      parameters:
        region: us-east-1
EOF
  ]
}

resource "kubernetes_storage_class" "rook_raw_block" {
  metadata {
    name = "rook-raw-block"
  }
  storage_provisioner = "pd.csi.storage.gke.io"
  volume_binding_mode = "WaitForFirstConsumer"
  parameters = {
    type = "pd-balanced"
  }
}
