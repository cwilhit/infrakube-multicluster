# Infrakube

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

## Community

Join the channel: https://discord.gg/J5vRmT2PWg

