# Infrakube Multicluster Edition

> [!IMPORTANT]
> **This is an unofficial, privately maintained fork of [galleybytes/infrakube](https://github.com/galleybytes/infrakube).**
>
> It adds experimental multicluster mode so a single Infrakube control plane can reconcile `Terraform` and `Tofu` resources across multiple registered workload clusters via [`sigs.k8s.io/multicluster-runtime`](https://github.com/kubernetes-sigs/multicluster-runtime).
>
> This fork is **not affiliated with or endorsed by the upstream Infrakube maintainers**. There are **no support, stability, or compatibility guarantees**. APIs and behavior may change without notice, and breaking rebases on upstream are expected. Use at your own risk; for production use cases, prefer the upstream project.
>
> Issues and PRs specific to the multicluster work belong here. Upstream Infrakube issues should be filed at [galleybytes/infrakube](https://github.com/galleybytes/infrakube/issues).

See [docs/multicluster-setup.md](docs/multicluster-setup.md) and [test/e2e/multicluster/README.md](test/e2e/multicluster/README.md) for how to try the multicluster mode.

A Kubernetes controller for running Terraform and other Infrastructure as Code workflows.

Infrakube is the successor to [terraform-operator](https://github.com/galleybytes/terraform-operator). It uses the same `kind: Terraform` resource and keeps familiar spec fields like `terraformVersion`, `terraformModule`, and `images.terraform`, making migration straightforward. The main change is the API group, which moves from `tf.galleybytes.com` to `infrakube.galleybytes.com`.

## Features

- Runs Terraform `init`, `plan`, and `apply` as Kubernetes pods
- Supports all Terraform versions from 0.12 through 1.14 out of the box
- Module downloads via git, https, and other sources supported by go-getter
- Kubernetes, S3, GCS, and other Terraform backends
- AWS IRSA, GCP Workload Identity, and other cloud auth methods
- Task plugins for custom pre/post workflows
- Monitor plugins for notifications and observability
- Optional multicluster runtime support for reconciling Terraform and OpenTofu resources across registered clusters

## Quick Start

```yaml
apiVersion: infrakube.galleybytes.com/v1
kind: Terraform
metadata:
  name: my-infra
spec:
  terraformVersion: "1.5.7"
  terraformModule:
    source: https://github.com/example/module.git?ref=main
  backend: |-
    terraform {
      backend "kubernetes" {
        secret_suffix     = "my-infra"
        in_cluster_config = true
      }
    }
```

## Multicluster Runtime

Infrakube can run one controller in a host cluster while reconciling `Terraform` and `Tofu` resources in multiple workload clusters. Enable this with `--enable-multicluster=true`.

Workload clusters are registered by creating kubeconfig Secrets in the host cluster. By default the controller watches `infrakube-system` for Secrets labeled `infrakube.galleybytes.com/cluster=true`, reads kubeconfig bytes from the `kubeconfig` data key, and uses `infrakube.galleybytes.com/cluster-name` as the optional logical cluster name.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: workload-east
  namespace: infrakube-system
  labels:
    infrakube.galleybytes.com/cluster: "true"
    infrakube.galleybytes.com/cluster-name: workload-east
stringData:
  kubeconfig: |-
    apiVersion: v1
    kind: Config
    clusters: []
    contexts: []
    users: []
```

Each workload cluster must have the Infrakube CRDs installed and the kubeconfig identity must be allowed to watch and manage the resources Infrakube creates there. The cache server URL injected into task pods must also be reachable from workload clusters, or set `--cache-url` to a reachable endpoint.

For the complete setup guide, see [`docs/multicluster-setup.md`](docs/multicluster-setup.md). For the local kind smoke harness, see [`test/e2e/multicluster/README.md`](test/e2e/multicluster/README.md).

## Support expectations

The automated suite is meant to prove controller behavior, task orchestration, and basic workflow execution. It does not try to cover every provider or cloud-specific module in the default CI path. If stronger proof is needed later, sandbox cloud smoke tests can live in separate nightly or manually triggered workflows.

For local test workflow details, see [`docs/testing.md`](docs/testing.md).

## Community

Join the channel: https://discord.gg/J5vRmT2PWg
