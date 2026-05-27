#!/usr/bin/env bash
# Swap the SkyPilot config mounted into the API server pod.
#
# Usage:
#   helm-swap-config.sh <path-to-skypilot-config.yaml>
#
# After running this, the host-side `kubectl port-forward` (if any) must be
# restarted because the old API pod (its bind target) was deleted.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <path-to-skypilot-config.yaml>" >&2
  exit 2
fi

CFG="$1"

log "running helm upgrade with new config from $CFG ..."
helm upgrade skypilot "$CHART_PATH" \
  --namespace "$SKYPILOT_NS" \
  --reuse-values \
  --set-file apiService.config="$CFG" \
  --wait --timeout 5m > "$RESULTS_DIR/helm-upgrade.log" 2>&1
log "helm upgrade complete"

# The chart's `apiService.config` change only updates the ConfigMap; the
# deployment spec is unchanged so the existing pod doesn't roll. Force a
# bounce so the new pod re-reads /root/.sky/config.yaml.
log "deleting current API pod to force ConfigMap re-read"
kubectl delete pod -n "$SKYPILOT_NS" -l app=skypilot-api --wait=true \
  > "$RESULTS_DIR/helm-pod-delete.log" 2>&1

log "waiting for new API pod Ready (up to 240s)..."
sleep 3  # let the new ReplicaSet pod appear
kubectl wait --for=condition=Ready pod -n "$SKYPILOT_NS" \
  -l app=skypilot-api --timeout=240s \
  > "$RESULTS_DIR/helm-pod-wait.log" 2>&1

log "new pod ready; giving API server 5s to bootstrap"
sleep 5
log "done"
echo
echo "NOTE: restart your port-forward — the old API pod's bind is gone."
