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

  # cephClusterSpec.monitoring.enabled below (in rook_ceph_cluster) makes Rook try
  # to create ServiceMonitors for mgr/exporter, but only this operator-chart flag
  # grants the RBAC to do so. Without it, ceph-cluster-controller's reconcile
  # fails at "enable mgr services" on every attempt and never reaches OSD setup.
  set {
    name  = "monitoring.enabled"
    value = "true"
  }

  # GKE reserves system-node-critical/system-cluster-critical priority classes for
  # GKE-managed namespaces (enforced by the warden admission webhook); the chart
  # defaults CSI plugin/provisioner pods to them, which GKE then rejects outright.
  set {
    name  = "csi.pluginPriorityClassName"
    value = ""
  }

  set {
    name  = "csi.provisionerPriorityClassName"
    value = ""
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
  # GKE rejects system-node-critical/system-cluster-critical (the chart's
  # defaults) outside GKE-managed namespaces via its warden admission webhook.
  priorityClassNames:
    mon: ""
    osd: ""
    mgr: ""
  # The chart's default OSD request (1 CPU) saturates e2-standard-4 nodes once
  # GKE's own DaemonSets and the mon/mgr pods are accounted for. This is a
  # low-traffic test cluster for thump, not a performance benchmark, so trim
  # requests instead of paying for bigger nodes.
  resources:
    mon:
      requests:
        cpu: 100m
        memory: 512Mi
    mgr:
      requests:
        cpu: 100m
        memory: 512Mi
    osd:
      requests:
        cpu: 250m
        memory: 2Gi
      limits:
        memory: 4Gi
  storage:
    useAllNodes: false
    useAllDevices: false
    storageClassDeviceSets:
    - name: rook-gke-osds
      count: 3
      portable: true
      # Without this, nothing stops all 3 device sets' PVCs (and therefore all 3
      # OSD pods) from landing on the same zone/node — which is exactly what
      # happened here, cramming 3 OSDs onto one e2-standard-4 while the other
      # two nodes sat idle. Spread one per node, same as Rook already does for mons.
      preparePlacement:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchExpressions:
                - key: app
                  operator: In
                  values:
                  - rook-ceph-osd
                  - rook-ceph-osd-prepare
              topologyKey: kubernetes.io/hostname
      placement:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchExpressions:
                - key: app
                  operator: In
                  values:
                  - rook-ceph-osd
                  - rook-ceph-osd-prepare
              topologyKey: kubernetes.io/hostname
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
# MDS priority class/resources live here, NOT in cephClusterSpec.priorityClassNames/
# resources (those don't have an "mds" key Rook actually reads for this daemon —
# confirmed the hard way: setting cephClusterSpec.priorityClassNames.mds was
# silently accepted by the permissive CRD schema and had zero effect). The MDS
# deployment's priority class and 1-CPU/4Gi resource defaults live on the
# CephFilesystem's spec.metadataServer instead.
cephFileSystems:
  - name: ceph-filesystem
    spec:
      metadataPool:
        replicated:
          size: 3
      dataPools:
        - failureDomain: host
          replicated:
            size: 3
          name: data0
      metadataServer:
        activeCount: 1
        activeStandby: true
        priorityClassName: ""
        resources:
          requests:
            cpu: 100m
            memory: 512Mi
          limits:
            memory: 2Gi
    storageClass:
      enabled: true
      isDefault: false
      name: ceph-filesystem
      pool: data0
      reclaimPolicy: Delete
      allowVolumeExpansion: true
      volumeBindingMode: "Immediate"
      parameters:
        csi.storage.k8s.io/provisioner-secret-name: rook-csi-cephfs-provisioner
        csi.storage.k8s.io/provisioner-secret-namespace: rook-ceph
        csi.storage.k8s.io/controller-expand-secret-name: rook-csi-cephfs-provisioner
        csi.storage.k8s.io/controller-expand-secret-namespace: rook-ceph
        csi.storage.k8s.io/controller-publish-secret-name: rook-csi-cephfs-provisioner
        csi.storage.k8s.io/controller-publish-secret-namespace: rook-ceph
        csi.storage.k8s.io/node-stage-secret-name: rook-csi-cephfs-node
        csi.storage.k8s.io/node-stage-secret-namespace: rook-ceph
        csi.storage.k8s.io/fstype: ext4

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
