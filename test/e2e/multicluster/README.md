# Multicluster E2E Smoke Test

This directory contains an optional kind-based smoke test for Infrakube multicluster runtime support.

## Topology

The harness uses three kind clusters:

| Cluster | Role |
| --- | --- |
| `infrakube-host` | Runs the Infrakube controller and stores workload cluster kubeconfig Secrets. |
| `infrakube-consumer-1` | Workload cluster used for the Terraform fixture. |
| `infrakube-consumer-2` | Workload cluster used for the Tofu fixture. |

The host controller discovers the two workload clusters via Secrets labeled `infrakube.galleybytes.com/cluster=true`. The test installs Infrakube CRDs on all three clusters because `Terraform` and `Tofu` are static CRDs.

## Prerequisites

- Docker
- kind
- kubectl
- controller and task images that are pullable or already present locally

By default the harness uses:

```bash
CONTROLLER_IMAGE=ghcr.io/galleybytes/infrakube:e2e
TASK_IMAGE=ghcr.io/galleybytes/infrakube-task:e2e
```

Override them for local or CI images:

```bash
CONTROLLER_IMAGE=ghcr.io/galleybytes/infrakube:0.0.0-<sha> \
TASK_IMAGE=ghcr.io/galleybytes/infrakube-task:0.0.0-<sha> \
make test-e2e-multicluster
```

If those images exist locally, the script loads them into each kind cluster. Otherwise kind will pull them when Pods start.

## Quick Start

```bash
make test-e2e-multicluster
```

That target runs:

1. `setup.sh`
2. `test-multicluster.sh`

Cleanup is explicit so failed clusters remain inspectable:

```bash
test/e2e/multicluster/cleanup.sh
```

## Manual Flow

```bash
# 1. Create host and workload clusters, install CRDs, and register workloads.
test/e2e/multicluster/setup.sh

# 2. Deploy the controller with MCR enabled and run remote fixtures.
test/e2e/multicluster/test-multicluster.sh

# 3. Inspect or clean up.
test/e2e/multicluster/cleanup.sh
```

## What It Verifies

- Host cluster can discover workload clusters from kubeconfig Secrets.
- MCR watches `Terraform` and `Tofu` resources in workload clusters.
- Reconcilers use the workload cluster client for task resources and status updates.
- Terraform runs to `completed` in `infrakube-consumer-1`.
- Tofu runs to `completed` in `infrakube-consumer-2`.
- Status outputs are written back to the remote parent resources.

## Notes

The controller is started with `--cache-url=` so remote task Pods skip the host-cluster cache service and use direct downloads or bundled binaries. This avoids cross-cluster service routing assumptions in kind.

For production multicluster deployments, point `--cache-url` at a cache endpoint reachable from every workload cluster or keep direct downloads enabled.

