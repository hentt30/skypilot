# Workspace-namespace precedence — Kubernetes e2e

End-to-end verification of the per-workspace Kubernetes namespace resolver
introduced in PR #9640. Confirms that all four precedence layers of
`get_effective_namespace` produce the correct pod placement on a live
cluster.

## What this tests

PR #9640 lets workspaces sharing a single physical Kubernetes cluster
target different namespaces, without synthesizing one kubeconfig context
per namespace. The resolver consults four config layers, most-specific
wins:

1. `workspaces.<ws>.kubernetes.context_configs.<ctx>.namespace`
2. `workspaces.<ws>.kubernetes.namespace`
3. `kubernetes.context_configs.<ctx>.namespace`
4. `kubernetes.namespace`
5. (none — caller falls back to the kubeconfig context default)

Layer 5 is exercised by the existing unit tests
(`tests/test_config.py::test_get_effective_namespace_no_config`,
`tests/unit_tests/kubernetes/test_kubernetes_utils.py::TestGetNamespace::test_falls_back_to_kubeconfig_when_unset`).
This e2e exercises layers 1-4 with real `sky launch` calls against a kind
cluster and asserts pod placement via `kubectl get pods`.

## Layout

```
workspace_namespace_precedence/
├── README.md                 # this file
├── configs/
│   ├── kind-cluster.yaml             # kind cluster spec
│   ├── helm-values.yaml              # chart values for the e2e deploy
│   ├── skypilot-config.yaml          # multi-layer config (L1-L3b cases)
│   └── skypilot-config-l4-only.yaml  # isolation config for L4
├── tasks/
│   └── sleep.sky.yaml                # minimal task used by every case
└── scripts/
    ├── _common.sh                    # path + env setup, sourced by all
    ├── setup-cluster.sh              # kind + namespaces + helm install
    ├── run-one-case.sh               # runs ONE case, streams live progress
    ├── cleanup-clusters.sh           # tears down all ns-e2e-* clusters + orphan pods
    └── helm-swap-config.sh           # swap apiService.config and bounce the pod
```

## Test matrix

The shared multi-layer config (`configs/skypilot-config.yaml`) sets layers
3 and 4 globally and adds workspace-scoped overrides for layers 1 and 2.
Each case is a `sky launch` issued under a different workspace, which
exercises one layer:

| Case  | Workspace            | Active layer                          | Expected namespace               |
|-------|----------------------|---------------------------------------|----------------------------------|
| L1    | `ws-per-context`     | workspace per-context (overrides all) | `ns-layer1-ws-per-context`       |
| L2    | `ws-cloud-shorthand` | workspace cloud-level (overrides L3+L4) | `ns-layer2-ws-cloud-shorthand`   |
| L3    | `default`            | global per-context (overrides L4)     | `ns-layer3-global-per-ctx`       |
| L3b   | `ws-no-overrides`    | workspace declared but no override; falls through to L3 | `ns-layer3-global-per-ctx` |
| L4    | `default` (separate config — see below) | global cloud-level     | `ns-layer4-global`               |

L4 cannot be exercised under the multi-layer config because layer 3 is
also set for the same context and (correctly) shadows L4. To isolate L4,
swap to `configs/skypilot-config-l4-only.yaml` (which omits the global
per-context entry) using `scripts/helm-swap-config.sh` before running the
L4 case.

## Failure modes the matrix catches

| Failure                                                            | Surfaces as                                                       |
|--------------------------------------------------------------------|-------------------------------------------------------------------|
| Resolver loses workspace per-context override                      | L1 lands in `ns-layer2-ws-cloud-shorthand`                        |
| Resolver loses workspace cloud-level shorthand                     | L2 lands in `ns-layer3-global-per-ctx`                            |
| Workspace override leaks across workspaces                         | L3b lands in `ns-layer1-...` or `ns-layer2-...`                   |
| `get_namespace` not consulting the workspace at all                | L1 and L2 both land in `ns-layer3-global-per-ctx`                 |
| `make_deploy_resources_variables` not passing through the workspace context | All cases land in `default`                              |
| Workspace cloud-level shorthand schema regressed                   | `helm install` fails because config validation rejects the value  |
| Global cloud-level (layer 4) reachability lost                     | L4 lands in `default` (kubeconfig fallback) instead of `ns-layer4-global` |

## Running it

### One-time per session

```bash
# 1. Build the image for this branch (only needed once; ~10-15 min cold)
docker buildx build --platform linux/arm64 --load \
  -t skypilot:ws-namespace-e2e -f Dockerfile .

# 2. Bring up the cluster + install SkyPilot with the multi-layer config
bash tests/kubernetes/workspace_namespace_precedence/scripts/setup-cluster.sh

# 3. Port-forward in a separate terminal (leave running)
kubectl -n skypilot port-forward svc/skypilot-api-service 30050:80

# 4. Point the sky CLI at the local API server
source .venv/bin/activate
sky api login -e http://127.0.0.1:30050
```

### Per case (live progress)

Each case streams progress to stdout and writes per-case logs under
`/tmp/skypilot-e2e/results/` (configurable via `E2E_RESULTS_DIR`).

```bash
bash tests/kubernetes/workspace_namespace_precedence/scripts/run-one-case.sh \
     L1 ws-per-context     ns-layer1-ws-per-context

bash tests/kubernetes/workspace_namespace_precedence/scripts/run-one-case.sh \
     L2 ws-cloud-shorthand ns-layer2-ws-cloud-shorthand

bash tests/kubernetes/workspace_namespace_precedence/scripts/run-one-case.sh \
     L3 default            ns-layer3-global-per-ctx

bash tests/kubernetes/workspace_namespace_precedence/scripts/run-one-case.sh \
     L3b ws-no-overrides   ns-layer3-global-per-ctx
```

### Between passes (config swap for L4)

```bash
# Tear down the pass-1 clusters
bash tests/kubernetes/workspace_namespace_precedence/scripts/cleanup-clusters.sh

# Swap to the L4-isolation config (this bounces the API pod —
# restart your port-forward afterwards)
bash tests/kubernetes/workspace_namespace_precedence/scripts/helm-swap-config.sh \
     tests/kubernetes/workspace_namespace_precedence/configs/skypilot-config-l4-only.yaml

# Restart port-forward in your other terminal, then:
bash tests/kubernetes/workspace_namespace_precedence/scripts/run-one-case.sh \
     L4 default ns-layer4-global

# Final cleanup
bash tests/kubernetes/workspace_namespace_precedence/scripts/cleanup-clusters.sh
```

## Results — 2026-05-27 run

Commit under test: `1465f8d97a19c5aee03e4dd4e8b4f3addc25caa4-dirty`
(post-rebase onto `upstream/master` including the `kubernetes<36` pin
from `fa31a4b2c`).

| Case  | Workspace            | Expected ns                       | Actual ns                         | Time | Result   |
|-------|----------------------|-----------------------------------|-----------------------------------|------|----------|
| L1    | `ws-per-context`     | `ns-layer1-ws-per-context`        | `ns-layer1-ws-per-context`        | 5s   | PASS     |
| L2    | `ws-cloud-shorthand` | `ns-layer2-ws-cloud-shorthand`    | `ns-layer2-ws-cloud-shorthand`    | 16s  | PASS     |
| L3    | `default`            | `ns-layer3-global-per-ctx`        | `ns-layer3-global-per-ctx`        | 80s  | PASS     |
| L3b   | `ws-no-overrides`    | `ns-layer3-global-per-ctx`        | `ns-layer3-global-per-ctx`        | 72s  | PASS     |
| L4    | `default`            | `ns-layer4-global`                | `ns-layer4-global`                | 23s  | PASS     |

All five cases passed. Each case exercises a different precedence layer of
`get_effective_namespace`, and the matrix exercises every documented
precedence boundary (L1 > L2 > L3 > L4, plus no-leakage across workspaces).

## Notable gotchas surfaced by this e2e

- **Chart's `apiService.config` is install-only.** On `helm upgrade`, the
  chart prints `WARNING: apiService.config is set during an upgrade
  operation, which will be IGNORED.` `helm-swap-config.sh` works around
  this by combining `--set-file` with `--reuse-values` and explicitly
  bouncing the API pod with `kubectl delete pod -l app=skypilot-api`.
- **Chart enforces 4 CPU / 8 GiB minimum** for the API server. Single-node
  kind clusters need `apiService.skipResourceCheck=true` plus an explicit
  modest `resources` override (set in `configs/helm-values.yaml`).
- **In-cluster context name is `in-cluster`** (per
  `DEFAULT_IN_CLUSTER_REGION`), not the host kubeconfig context name.
  Config keys under `kubernetes.context_configs.*` and per-workspace
  `context_configs.*` must use `in-cluster` for in-cluster deployments.
- **Pod label `skypilot-cluster` has a hash suffix** (e.g.
  `ns-e2e-ws-per-context-c2d2a02b`), not the raw user-facing cluster
  name. The runner matches pods by **name prefix** combined with the
  `skypilot-head-node=1` label rather than by label equality.

## Out of scope here

- **L5 (kubeconfig fallback)** — covered by unit tests; the in-cluster
  `DEFAULT_IN_CLUSTER_REGION` context has no kubeconfig defaults to fall
  back to, so it can't be exercised in this fixture.
- **SSH-path namespace isolation** — covered by
  `tests/unit_tests/test_sky/clouds/test_ssh.py::TestSSHMakeDeployResourcesVariables::test_ssh_cloud_does_not_leak_global_kubernetes_namespace`.
- **`check_credentials` workspace-resolved RBAC probe** — covered by
  `tests/unit_tests/kubernetes/test_kubernetes_utils.py::TestCheckCredentials`.
  An e2e variant would require setting up RBAC differences across the
  test namespaces.

## Tear-down

```bash
kind delete cluster --name skypilot-e2e
```
