variable "project_id" {
  description = "The GCP Project ID where resources will be provisioned."
  type        = string
  default     = "terraform-sandbox-430820"
}

variable "region" {
  description = "The GCP region to provision regional resources (e.g. GKE cluster, subnets)."
  type        = string
  default     = "us-central1"
}

variable "cluster_name" {
  description = "The name of the GKE cluster and prefix for related resources."
  type        = string
  default     = "rook-ceph-gke"
}

