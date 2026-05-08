#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# destroy.sh — Safe Terraform destroy wrapper
#
# Usage:
#   bash scripts/destroy.sh               # interactive confirmation
#   bash scripts/destroy.sh -auto-approve # non-interactive
#
# Why this script exists:
#   terraform destroy can fail or leave orphaned OCI resources for two reasons:
#
#   1. The OCI Block Volume backing the NFS server PVC is orphaned if the
#      CSI driver is killed before it can call the OCI API. The CSI driver's
#      DeleteVolume is async — Helm uninstall reports "complete" once the k8s
#      objects are marked for deletion, but the actual OCI API call may still
#      be in-flight when the node pool is torn down and the CSI controller pod
#      is killed. This script deletes namespaces via kubectl first, blocking
#      until namespace deletion completes (which confirms the OCI volume was
#      deleted), before the node pool is ever touched.
#
#   2. The Helm/Kubernetes provider times out with "context deadline exceeded"
#      when the OKE API server becomes unreachable after nodes are terminated.
#
# Requires: terraform, kubectl
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# ── Step 1: Delete namespaces to ensure CSI cleans up OCI Block Volumes ───────
# Deletion order matters:
#
#   a) n8n first: terminates the n8n pod, clears the pvc-protection finalizer
#      on n8n-data, NFS provisioner (still running in nfs-storage) deletes the
#      backing subdirectory, PVC is removed. No OCI Block Volume involved.
#
#   b) nfs-storage: terminates the NFS server pod, clears the pvc-protection
#      finalizer on the backing PVC, the k8s reclaim controller invokes the
#      CSI driver's DeleteVolume gRPC, CSI calls the OCI Block Volume API to
#      delete the volume, CSI removes the PV finalizer, PV is deleted, namespace
#      deletion completes. kubectl --wait=true blocks here, guaranteeing the
#      OCI Block Volume is gone before we proceed to destroy the node pool.
#
#   c) tunnel: no backing OCI volumes, clean up while the API is reachable.
#
# If the cluster is unreachable, volumes must be deleted manually:
#   oci bv volume delete --volume-id <id> --force

echo "Deleting application namespaces (ensures CSI cleans up OCI Block Volumes)..."
if kubectl get nodes &>/dev/null 2>&1; then
  kubectl delete namespace n8n       --ignore-not-found --wait=true --timeout=120s || true
  kubectl delete namespace nfs-storage --ignore-not-found --wait=true --timeout=180s || true
  kubectl delete namespace tunnel    --ignore-not-found --wait=true --timeout=60s  || true
  echo "Namespace cleanup complete."
else
  echo "Cluster not reachable — skipping cleanup."
  echo "Orphaned OCI Block Volumes must be deleted manually:"
  echo "  oci bv volume list --compartment-id <tenancy-ocid> | grep csi-"
  echo "  oci bv volume delete --volume-id <id> --force"
fi

echo ""

# ── Step 2: Remove in-cluster resources from state ────────────────────────────
# Namespaces and their contents are already gone; removing from state so
# terraform destroy does not try to contact a dead API server for them.

echo "Removing in-cluster resources from Terraform state..."
echo "(OKE cluster deletion removes any remaining Kubernetes resources automatically)"
echo ""

removed=0
while IFS= read -r resource; do
  [[ -z "$resource" ]] && continue
  echo "  Removing: $resource"
  terraform state rm "$resource" && ((removed += 1)) || true
done < <(terraform state list 2>/dev/null \
  | grep -E '^(kubernetes_|helm_release\.)' || true)

if [[ $removed -eq 0 ]]; then
  echo "  Nothing to remove — state already clean."
fi

echo ""

# ── Step 3: Destroy OCI infrastructure ────────────────────────────────────────

terraform destroy "$@"
