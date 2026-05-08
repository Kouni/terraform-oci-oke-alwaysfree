#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# destroy.sh — Safe Terraform destroy wrapper
#
# Usage:
#   bash scripts/destroy.sh               # interactive confirmation
#   bash scripts/destroy.sh -auto-approve # non-interactive
#
# Why this script exists:
#   terraform destroy can hang on Kubernetes resources for two reasons:
#
#   1. kubernetes_namespace_v1 gets stuck in Terminating because the NFS PVC
#      inside it holds a Kubernetes finalizer, and prevent_destroy = true
#      prevents Terraform from deleting the PVC cleanly.
#
#   2. The Helm/Kubernetes provider times out with "context deadline exceeded"
#      when the OKE API server becomes unreachable mid-destroy (e.g. after
#      nodes are terminated).
#
#   Since OCI destroys all in-cluster resources (namespaces, PVCs, Deployments,
#   Helm releases) when the OKE cluster is deleted, Terraform does not need to
#   manage their individual deletion. This script removes them from state first,
#   then lets terraform destroy clean up the OCI layer.
#
# Requires: terraform, jq (optional)
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# ── Step 1: Remove in-cluster resources from state ────────────────────────────

echo "Removing in-cluster resources from Terraform state..."
echo "(OKE cluster deletion removes all Kubernetes resources automatically)"
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

# ── Step 2: Destroy OCI infrastructure ────────────────────────────────────────

terraform destroy "$@"
