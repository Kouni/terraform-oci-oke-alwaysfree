#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# oci-audit.sh — Full OCI account resource audit
#
# Usage:
#   ./scripts/oci-audit.sh                  # auto-detect profile & region
#   ./scripts/oci-audit.sh DEFAULT ap-tokyo-1
#
# Requires: oci-cli, python3
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

OCI_PROFILE="${1:-DEFAULT}"
REGION="${2:-$(oci iam region list --query 'data[0].name' --raw-output 2>/dev/null || echo "ap-tokyo-1")}"
TENANCY=$(oci iam compartment list --all --compartment-id-in-subtree true \
  --query "data[?\"compartment-id\"==''] | [0].\"compartment-id\"" \
  --raw-output 2>/dev/null || \
  grep "^tenancy=" ~/.oci/config | head -1 | cut -d= -f2)

# Fall back: read tenancy directly from config
if [[ -z "$TENANCY" ]]; then
  TENANCY=$(grep "^tenancy=" ~/.oci/config | head -1 | cut -d= -f2)
fi

REGION=$(grep "^region=" ~/.oci/config | head -1 | cut -d= -f2)

echo "============================================================"
echo "  OCI Account Resource Audit"
echo "  Profile : $OCI_PROFILE"
echo "  Region  : $REGION"
echo "  Tenancy : ${TENANCY:0:40}..."
echo "  Time    : $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "============================================================"
echo ""

# ──────────────────────────────────────────────────────────────────────────────
# Helper: query OCI Search (covers ~200+ resource types across all services)
# ──────────────────────────────────────────────────────────────────────────────
CHARGEABLE=(
  Instance BootVolume Volume VolumeBackup BootVolumeBackup VolumeGroup
  Cluster NodePool
  LoadBalancer NetworkLoadBalancer
  Vcn Subnet InternetGateway NatGateway ServiceGateway RouteTable
  Bucket
  AutonomousDatabase DbSystem
  FileSystem MountTarget
  Budget
  StreamPool Stream
  DataScienceNotebookSession
  FunctionApplication
  ApiGateway
)

echo "🅐 Global Resource Inventory (OCI Search Service)"
echo "──────────────────────────────────────────────────"
oci search resource structured-search \
  --query-text "query all resources where (lifecycleState != 'DELETED' && lifecycleState != 'TERMINATED')" \
  --raw-output 2>/dev/null | python3 -c "
import json, sys
CHARGEABLE = {
  'Instance','BootVolume','Volume','VolumeBackup','BootVolumeBackup','VolumeGroup',
  'Cluster','NodePool',
  'LoadBalancer','NetworkLoadBalancer',
  'Vcn','Subnet','InternetGateway','NatGateway','ServiceGateway','RouteTable',
  'Bucket',
  'AutonomousDatabase','DbSystem',
  'FileSystem','MountTarget',
  'Budget',
  'StreamPool','Stream',
  'DataScienceNotebookSession',
  'FunctionApplication',
  'ApiGateway',
}
from collections import Counter
raw = json.load(sys.stdin)
items = raw.get('data', {}).get('items', [])
c = Counter(i.get('resource-type','?') for i in items)

chargeable_found = []
print(f\"  {'TYPE':<42} {'COUNT':>5}  RISK\")
print('  ' + '-'*56)
for rtype, count in sorted(c.items(), key=lambda x: (-x[1], x[0])):
    risk = '*** CHARGEABLE ***' if rtype in CHARGEABLE else ''
    if risk:
        chargeable_found.append((rtype, count))
    print(f\"  {rtype:<42} {count:>5}  {risk}\")

print()
print(f'  Total non-terminal resources: {len(items)}')
if chargeable_found:
    print()
    print('  ATTENTION — Chargeable resource types found:')
    for rtype, count in chargeable_found:
        print(f'    - {rtype}: {count}')
else:
    print('  No chargeable resources detected via Search.')
"

echo ""
echo "🅑 Block Volumes (incl. CSI orphans)"
echo "──────────────────────────────────────"
oci bv volume list --compartment-id "$TENANCY" --region "$REGION" --all \
  --query 'data[?contains(`["AVAILABLE","PROVISIONING","RESTORING","FAULTY"]`, "lifecycle-state")].{name:"display-name",state:"lifecycle-state",gb:"size-in-gbs",id:"id"}' \
  --output table 2>&1 || echo "  (none or error)"

echo ""
echo "🅒 Boot Volumes"
echo "──────────────────────────────────────"
ADS=$(oci iam availability-domain list --compartment-id "$TENANCY" \
  --query 'data[*].name' --raw-output 2>/dev/null | tr -d '[]"' | tr ',' '\n')
for AD in $ADS; do
  echo "  AD: $AD"
  oci bv boot-volume list --compartment-id "$TENANCY" \
    --region "$REGION" --availability-domain "$AD" --all \
    --query 'data[?`lifecycle-state` != `TERMINATED`].{name:"display-name",state:"lifecycle-state",gb:"size-in-gbs"}' \
    --output table 2>&1 || echo "  (none)"
done

echo ""
echo "🅓 Load Balancers"
echo "──────────────────────────────────────"
oci lb load-balancer list --compartment-id "$TENANCY" --region "$REGION" --all \
  --query 'data[?`lifecycle-state` != `DELETED`].{name:"display-name",state:"lifecycle-state",shape:"shape-name"}' \
  --output table 2>&1 || echo "  (none)"

echo ""
echo "🅔 Budget"
echo "──────────────────────────────────────"
oci budgets budget budget list --compartment-id "$TENANCY" --all \
  --query 'data[*].{name:"display-name",amount:"amount",spent:"actual-spend",state:"lifecycle-state"}' \
  --output table 2>&1 || echo "  (none)"

echo ""
echo "🅕 Untagged Resources (missing 'alwaysfree' freeform tag)"
echo "──────────────────────────────────────────────────────────"
# IAM/system types that legitimately have no alwaysfree tag
SKIP_TYPES="TagDefault TagNamespace Policy App Group User Domain DomainPasswordPolicy CompartmentPasswordPolicy DynamicGroup IdentityProvider"
oci search resource structured-search \
  --query-text "query all resources where (lifecycleState != 'DELETED' && lifecycleState != 'TERMINATED')" \
  --raw-output 2>/dev/null | python3 -c "
import json, sys
SKIP = set('$SKIP_TYPES'.split())
raw = json.load(sys.stdin)
items = raw.get('data',{}).get('items',[])
untagged = [
    i for i in items
    if i.get('resource-type') not in SKIP
    and 'alwaysfree' not in (i.get('freeform-tags') or {})
]
if untagged:
    print(f\"  {'TYPE':<42} {'NAME'}\")
    print('  ' + '-'*70)
    for i in untagged:
        print(f\"  {i.get('resource-type','?'):<42} {i.get('display-name','?')}\")
    print(f'\n  Total untagged infrastructure resources: {len(untagged)}')
else:
    print('  All infrastructure resources are properly tagged.')
"

echo ""
echo "============================================================"
echo "  Audit complete."
echo "============================================================"
