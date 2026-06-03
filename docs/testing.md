# Testing Infrakube

This guide explains what the automated test suite covers and how to run it locally.

## What the suite covers

| Layer | Command | Primary goal |
| --- | --- | --- |
| Unit | `make test-unit` | Cover high-risk behavior such as custom JSON marshaling, task option merging, image/default precedence, pod env generation, and guardrails around invalid task pod configuration. |
| Controller integration | `make test-integration` | Run the reconcilers against envtest and assert that Terraform and Tofu resources create the expected PVCs, secrets, configmaps, RBAC, service accounts, and pods. |
| Kind smoke | `make test-e2e` | Run the controller and task image on a real Kubernetes cluster and verify a Terraform workflow and a Tofu workflow both finish successfully. |
| Kind multicluster smoke | `make test-e2e-multicluster` | Run one host kind cluster and two workload kind clusters, register workload kubeconfigs, and verify remote Terraform and Tofu workflows through MCR. |

The default suite avoids paid infrastructure and long-lived secrets. It focuses on controller behavior and a small number of real workflow executions instead of trying to cover every provider combination.

## Local prerequisites

- Go matching `go.mod`
- Docker
- A Kubernetes cluster for `make test-e2e`, typically kind
- `kubectl` configured to point at the cluster you want to use for the smoke test
- `kind` for `make test-e2e-multicluster`

`make test-unit` and `make test-integration` do not require a live cluster. The integration target downloads envtest assets into `./testbin`.

## Common commands

```bash
make test-unit
make test-integration
make test
make test-e2e
make test-e2e-multicluster
```

`make test` is the main validation entrypoint and runs both the unit and envtest integration suites.

If you are changing controller logic, `make test` is the minimum useful check. If you are changing deploy behavior, task images, or workflow execution, run `make test-e2e` against a kind cluster as well.
If you are changing multicluster discovery, MCR controller setup, remote-client behavior, or cluster registration, run `make test-e2e-multicluster`.

## End-to-end smoke fixtures

The smoke harness lives in `test/e2e/kind-smoke.sh`. The Terraform and Tofu fixtures live in `test/e2e/manifests/terraform-inline.yaml` and `test/e2e/manifests/tofu-inline.yaml`.

Those fixtures use:

- inline modules, so the tests do not depend on an external example repository
- the Kubernetes backend, so state handling is exercised inside the cluster
- status outputs, so success is easy to assert from CI

## Multicluster smoke fixtures

The multicluster harness lives in `test/e2e/multicluster`:

- `setup.sh` creates one host kind cluster, two workload kind clusters, installs static Infrakube CRDs on all clusters, and registers workload kubeconfig Secrets on the host.
- `test-multicluster.sh` deploys the controller on the host with `--enable-multicluster=true`, applies the Terraform fixture to one workload cluster, applies the Tofu fixture to another workload cluster, and waits for remote status outputs.
- `cleanup.sh` deletes the kind clusters.

The multicluster smoke is optional and not part of the default CI path because it creates multiple clusters and is slower than the single-cluster smoke.

```bash
make test-e2e-multicluster
test/e2e/multicluster/cleanup.sh
```

## CI behavior

Pull requests targeting `master` trigger three workflows:

1. `Build Infrakube Container Image` publishes `ghcr.io/galleybytes/infrakube:0.0.0-<commit>` and reuses a cached content tag when the controller inputs are unchanged.
2. `Build Task Container Image` publishes `ghcr.io/galleybytes/infrakube-task:0.0.0-<commit>`.
3. `.github/workflows/ci.yaml` runs `make test`, waits for both build workflows to finish for the pull request head SHA, pulls those exact images from GHCR, loads them into kind, and runs the Terraform and Tofu smoke fixtures.

This keeps the default CI path free, secret-free, and easy to inspect.

Release image publishing is handled separately by the tag-driven workflows:

- `infrakube-*` tags still publish `latest`, the requested version tag, and an immutable `0.0.0-<commit>` tag for the controller image
- `task-*` tags still publish the requested version tag and an immutable `0.0.0-<commit>` tag for the task image
- `v*` tags now trigger both workflows, and both workflows strip the leading `v` before publishing the shared image tag while the controller image also updates `latest`

Pushes to `master` do not rerun the validation suite or release builds.

## What is not covered by default

The default suite does not prove every provider plugin, cloud IAM path, or external backend permutation. Those are better fits for optional nightly or manually triggered sandbox workflows.
