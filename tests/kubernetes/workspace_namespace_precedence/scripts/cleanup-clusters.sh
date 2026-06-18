#!/usr/bin/env bash
# Tear down all sky clusters whose names start with `ns-e2e-`. Idempotent.
set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

# Activate venv so `sky` is on PATH.
if [[ -f "$VENV_ACTIVATE" ]]; then
  # shellcheck disable=SC1090
  source "$VENV_ACTIVATE"
fi

CLUSTERS=$(sky status --no-show-managed-jobs --no-show-services 2>&1 | grep -E '^ns-e2e' | awk '{print $1}')
if [[ -z "$CLUSTERS" ]]; then
  echo "no ns-e2e- clusters to clean up"
  exit 0
fi

for c in $CLUSTERS; do
  echo "tearing down $c ..."
  sky down "$c" -y --purge 2>&1 | tail -2
done

# Also purge any orphan pods left in the test namespaces.
for ns in "${TEST_NAMESPACES[@]}"; do
  kubectl delete pods --all -n "$ns" --wait=false 2>&1 | tail -1
done

echo
echo "remaining e2e pods:"
kubectl get pods -A 2>&1 | grep -E 'ns-e2e|^NAMESPACE.*ns-layer' || echo "(none)"
