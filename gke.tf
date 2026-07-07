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

  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.subnet.id

  # Pinned away from us-central1-c: a prior apply hit GCE_STOCKOUT there for
  # e2-standard-4. a/b/f are confirmed available.
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
