# Enable Kubernetes Engine API
resource "google_project_service" "container" {
  project            = var.project_id
  service            = "container.googleapis.com"
  disable_on_destroy = false
}

# Regional GKE Cluster Definition
resource "google_container_cluster" "primary" {
  name     = var.cluster_name
  location = var.region
  project  = var.project_id

  # We cannot create a cluster without a node pool, so we create a default one
  # and delete it immediately to manage node pools separately.
  remove_default_node_pool = true
  initial_node_count       = 1

  # This is a disposable, destroy/rebuild-heavy test lab (see CLAUDE.md) -- the
  # google provider's default deletion_protection=true blocks exactly the
  # workflow this repo is built around, and just silently refused `tofu destroy`
  # with no plan-time warning.
  deletion_protection = false

  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.subnet.id

  # Pinned away from us-central1-c: a prior apply hit GCE_STOCKOUT there for
  # e2-standard-4. a/b/f are confirmed available -- don't drop to 2 zones,
  # even after a transient GCE_STOCKOUT in one of them (has happened in both
  # c and f on separate occasions, and self-resolved on retry): rook.tf's
  # monCount=3 + allowMultiplePerNode=false, and the storageClassDeviceSets
  # anti-affinity for 3 OSDs, both require 3 distinct nodes. A 2-zone pool
  # leaves the CephCluster permanently stuck ("cannot start 3 mons on 2
  # node(s)") with no mons and no OSDs ever created. If a zone is
  # persistently out of capacity, replace it with a real 4th option instead
  # of shrinking to 2 -- us-central1 only has a/b/c/f, so retrying the apply
  # is the practical fix for a transient stockout.
  node_locations = [
    "us-central1-a",
    "us-central1-b",
    "us-central1-f",
  ]

  ip_allocation_policy {
    cluster_secondary_range_name  = "gke-pods"
    services_secondary_range_name = "gke-services"
  }

  # Enable the GKE persistent disk CSI driver (default in modern clusters, enabled explicitly for clarity)
  addons_config {
    gce_persistent_disk_csi_driver_config {
      enabled = true
    }
  }

  # Ensure APIs are enabled before creating cluster
  depends_on = [
    google_project_service.container,
    google_project_service.compute
  ]

  # The provider's default 40m create timeout is too tight for this regional
  # (3-zone) cluster -- GKE creation here routinely runs 30-40+ min, and a
  # client-side timeout fires while GCP is still legitimately mid-CREATE_CLUSTER
  # (confirmed via `gcloud container operations describe`: state RUNNING, not
  # stuck). Tofu still records the resource once the create RPC returns, so the
  # timeout doesn't lose the resource -- but it does abort the rest of the apply
  # graph (node pool + everything downstream) for no real reason. Don't
  # interrupt/delete a cluster still in this state; verify via `gcloud
  # container operations list` first (see README "Known GKE Gotchas").
  timeouts {
    create = "60m"
  }
}

# Regional Node Pool definition (spread across zones in the region)
resource "google_container_node_pool" "primary_nodes" {
  name       = "${var.cluster_name}-node-pool"
  location   = var.region
  cluster    = google_container_cluster.primary.name
  node_count = 1 # 1 node per zone (default 3 zones in region = 3 nodes total)
  project    = var.project_id

  node_config {
    machine_type = "e2-standard-4"
    image_type   = "UBUNTU_CONTAINERD" # Required for rbd kernel module support (Ceph RBD)

    # OAuth scopes needed for standard operations
    oauth_scopes = [
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
      "https://www.googleapis.com/auth/servicecontrol",
      "https://www.googleapis.com/auth/service.management.readonly",
      "https://www.googleapis.com/auth/trace.append"
    ]

    # Best practice metadata configurations
    metadata = {
      disable-legacy-endpoints = "true"
    }
  }
}
