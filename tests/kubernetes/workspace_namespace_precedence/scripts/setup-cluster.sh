#!/usr/bin/env bash
# Bring up the kind cluster, create the test namespaces + RBAC, load the
# locally-built image, and install the SkyPilot chart with the multi-layer
# precedence config. Idempotent (delete-then-create the kind cluster).
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

echo "==> Recreating kind cluster $CLUSTER_NAME"
kind delete cluster --name "$CLUSTER_NAME" 2>/dev/null || true
kind create cluster --config "$CONFIGS_DIR/kind-cluster.yaml"

echo "==> Loading image $IMAGE_TAG into kind"
if ! docker image inspect "$IMAGE_TAG" > /dev/null 2>&1; then
  echo "ERROR: image $IMAGE_TAG not present locally. Build it first:" >&2
  echo "  docker buildx build --platform linux/arm64 --load -t $IMAGE_TAG -f Dockerfile ." >&2
  exit 1
fi
kind load docker-image "$IMAGE_TAG" --name "$CLUSTER_NAME"

# Note: SkyPilot's in-cluster context name is `in-cluster` (set by
# DEFAULT_IN_CLUSTER_REGION in sky/adaptors/kubernetes.py), independent
# of whatever the host's kubeconfig calls this cluster. Do NOT rename.
kubectl config use-context "kind-$CLUSTER_NAME"

echo "==> Creating namespaces"
kubectl create namespace "$SKYPILOT_NS" --dry-run=client -o yaml | kubectl apply -f -
for ns in "${TEST_NAMESPACES[@]}"; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

echo "==> Helm dependency build for skypilot chart"
helm dependency build "$CHART_PATH"

echo "==> Installing skypilot helm release"
# --set-file injects the skypilot-config.yaml verbatim into apiService.config
# (the chart renders this string into a ConfigMap mounted at
# /root/.sky/config.yaml inside the API pod).
helm upgrade --install skypilot "$CHART_PATH" \
  --namespace "$SKYPILOT_NS" \
  --create-namespace \
  --values "$CONFIGS_DIR/helm-values.yaml" \
  --set-file apiService.config="$CONFIGS_DIR/skypilot-config.yaml" \
  --wait --timeout 5m

echo "==> Granting SkyPilot SA cluster-wide perms (so it can land pods in any test namespace)"
# The chart already creates SA + ClusterRoleBinding when
# useApiServerCluster=true, but the default scope is namespace-only. Bind
# cluster-admin for the e2e test (NOT for production).
kubectl create clusterrolebinding skypilot-e2e-admin \
  --clusterrole=cluster-admin \
  --serviceaccount=${SKYPILOT_NS}:skypilot-api-sa \
  --dry-run=client -o yaml | kubectl apply -f -

echo
echo "==> Cluster + helm install complete. Next steps:"
echo
echo "  1. In one terminal:"
echo "     kubectl -n $SKYPILOT_NS port-forward svc/skypilot-api-service ${API_PORT}:80"
echo
echo "  2. In another terminal (or this one once port-forward is backgrounded):"
echo "     source $VENV_ACTIVATE"
echo "     sky api login -e http://127.0.0.1:${API_PORT}"
echo "     # Run cases one at a time (see README for the full matrix):"
echo "     bash $E2E_SCRIPT_DIR/run-one-case.sh L1 ws-per-context ns-layer1-ws-per-context"
echo
