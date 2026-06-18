#!/usr/bin/env bash
# End-to-end namespace-precedence test for PR #9640.
# Runs ONE case at a time so progress is visible and we can iterate.
#
# Usage:
#   run-one-case.sh <case-label> <workspace> <expected-namespace>
#
# Examples:
#   run-one-case.sh L1  ws-per-context     ns-layer1-ws-per-context
#   run-one-case.sh L2  ws-cloud-shorthand ns-layer2-ws-cloud-shorthand
#   run-one-case.sh L3  default            ns-layer3-global-per-ctx
#   run-one-case.sh L3b ws-no-overrides    ns-layer3-global-per-ctx
#   run-one-case.sh L4  default            ns-layer4-global  # requires helm-swap-config.sh
#
# Cluster cleanup is NOT automatic — call cleanup-clusters.sh between cases.
set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <case-label> <workspace> <expected-namespace>" >&2
  exit 2
fi

CASE_LABEL="$1"
WS="$2"
EXPECTED_NS="$3"

CLUSTER_NAME_USER="ns-e2e-${WS//[^a-z0-9-]/-}"
# Skypilot's K8s pod label `skypilot-cluster` carries a hash suffix
# (e.g. `ns-e2e-ws-per-context-c2d2a02b`), so label equality doesn't
# match — we filter by name prefix instead.

echo "================================================================"
echo "  CASE $CASE_LABEL: workspace=$WS  ->  expected=$EXPECTED_NS"
echo "  cluster name=$CLUSTER_NAME_USER"
echo "================================================================"
case_start=$(date +%s)

log "launching cluster '$CLUSTER_NAME_USER' (async) ..."
launch_start=$(date +%s)
if ! SKYPILOT_DEBUG=0 sky launch -c "$CLUSTER_NAME_USER" \
      --config "active_workspace=$WS" \
      --infra kubernetes \
      --cpus 0.5+ --memory 0.5+ --num-nodes 1 \
      -y --async \
      "$TASKS_DIR/sleep.sky.yaml" \
      2>&1 | tee "$RESULTS_DIR/launch-$CASE_LABEL.log"; then
  log "FAIL: sky launch returned non-zero (full log: $RESULTS_DIR/launch-$CASE_LABEL.log)"
  exit 1
fi
launch_elapsed=$(( $(date +%s) - launch_start ))
log "sky launch returned (async submit took ${launch_elapsed}s)"
echo

log "waiting for K8s head pod starting with '${CLUSTER_NAME_USER}-' (up to 240s)..."
pod_namespace="" pod_status="" elapsed=0
for i in $(seq 1 120); do
  pod_info=$(kubectl get pods -A -l skypilot-head-node=1 -o json 2>/dev/null \
    | python3 -c "
import json, sys
prefix = '${CLUSTER_NAME_USER}-'
data = json.load(sys.stdin)
for p in data.get('items', []):
    if p['metadata']['name'].startswith(prefix):
        print(p['metadata']['namespace'] + '|' + p['status']['phase'])
        break
" 2>/dev/null) || pod_info=""
  if [[ -n "$pod_info" && "$pod_info" != "|" ]]; then
    pod_namespace="${pod_info%|*}"
    pod_status="${pod_info#*|}"
    log "pod found: namespace=$pod_namespace phase=$pod_status (after ${elapsed}s)"
    break
  fi
  if (( i % 5 == 0 )); then
    log "  still waiting (${elapsed}s elapsed, ${i}/120 polls)..."
    request_id=$(grep -oE 'sky.launch request: [0-9a-f-]+' "$RESULTS_DIR/launch-$CASE_LABEL.log" | head -1 | awk '{print $NF}')
    if [[ -n "$request_id" ]]; then
      status_line=$(sky api status 2>/dev/null | grep -E "^${request_id:0:8}" | head -1)
      if [[ -n "$status_line" ]]; then
        log "  request: $status_line"
      fi
    fi
  fi
  sleep 2
  elapsed=$(( elapsed + 2 ))
done

if [[ -z "$pod_namespace" ]]; then
  log "FAIL: no pod with prefix '${CLUSTER_NAME_USER}-' within 240s"
  exit 1
fi

case_elapsed=$(( $(date +%s) - case_start ))
echo
echo "----------------------------------------------------------------"
if [[ "$pod_namespace" == "$EXPECTED_NS" ]]; then
  log "PASS in ${case_elapsed}s — pod in $pod_namespace (matches expected)"
  echo "----------------------------------------------------------------"
  exit 0
else
  log "FAIL in ${case_elapsed}s — pod in '$pod_namespace', expected '$EXPECTED_NS'"
  echo "----------------------------------------------------------------"
  exit 1
fi
