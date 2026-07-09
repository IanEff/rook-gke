#!/usr/bin/env bash

set -euo pipefail

# Default values mapped from terraform variables
PROJECT_ID=${PROJECT_ID:-"terraform-sandbox-430820"}
REGION=${REGION:-"us-central1"}
CLUSTER_NAME=${CLUSTER_NAME:-"rook-ceph-gke"}

echo "Using Project ID: $PROJECT_ID"
echo "Using Region: $REGION"
echo "Using Cluster Name: $CLUSTER_NAME"

echo "Attempting to delete GKE cluster..."
gcloud container clusters delete "${CLUSTER_NAME}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --quiet || echo "Cluster ${CLUSTER_NAME} already deleted or not found."

echo "Attempting to delete firewall rule..."
gcloud compute firewall-rules delete "${CLUSTER_NAME}-allow-internal" \
  --project="${PROJECT_ID}" \
  --quiet || echo "Firewall rule already deleted or not found."

echo "Attempting to delete subnetwork..."
gcloud compute networks subnets delete "${CLUSTER_NAME}-subnet" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --quiet || echo "Subnetwork already deleted or not found."

echo "Attempting to delete VPC network..."
gcloud compute networks delete "${CLUSTER_NAME}-vpc" \
  --project="${PROJECT_ID}" \
  --quiet || echo "VPC network already deleted or not found."

echo "Ripcord complete."
