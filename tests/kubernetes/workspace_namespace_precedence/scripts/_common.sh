#!/usr/bin/env bash
# Common setup sourced by all e2e scripts in this directory.
# Resolves the repo root + paths to the chart, configs, and venv.
set -uo pipefail

E2E_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_TEST_DIR="$(cd "$E2E_SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$E2E_TEST_DIR/../../.." && pwd)"

CHART_PATH="$REPO_ROOT/charts/skypilot"
VENV_ACTIVATE="$REPO_ROOT/.venv/bin/activate"

CONFIGS_DIR="$E2E_TEST_DIR/configs"
TASKS_DIR="$E2E_TEST_DIR/tasks"
# Place results in a workspace-writable scratch dir, not under the repo
# (avoids polluting git status).
RESULTS_DIR="${E2E_RESULTS_DIR:-/tmp/skypilot-e2e/results}"
mkdir -p "$RESULTS_DIR"

CLUSTER_NAME="${E2E_KIND_CLUSTER_NAME:-skypilot-e2e}"
SKYPILOT_NS="${E2E_SKYPILOT_NAMESPACE:-skypilot}"
IMAGE_TAG="${E2E_IMAGE_TAG:-skypilot:ws-namespace-e2e}"
API_PORT="${E2E_API_PORT:-30050}"

# Test namespaces used by the precedence matrix.
TEST_NAMESPACES=(
  ns-layer4-global
  ns-layer3-global-per-ctx
  ns-layer2-ws-cloud-shorthand
  ns-layer1-ws-per-context
)

log() {
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"
}
