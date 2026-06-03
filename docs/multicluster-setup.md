# Multicluster Setup

This guide explains how to run one Infrakube controller in a host cluster while reconciling `Terraform` and `Tofu` resources in one or more workload clusters.

## Overview

Infrakube supports two modes:

| Mode | Behavior |
| --- | --- |
| Single-cluster | Default. The controller watches and reconciles only the cluster where it runs. |
| Multicluster | The controller runs in a host cluster, discovers workload clusters from kubeconfig Secrets, and reconciles resources in every registered cluster. |

In multicluster mode:

- `Terraform` and `Tofu` resources can be created in the host cluster or any registered workload cluster.
- Task Pods, Secrets, ConfigMaps, PVCs, Jobs, and status updates are created on the same cluster as the parent `Terraform` or `Tofu` resource.
- Cluster registration is controlled by labeled kubeconfig Secrets in the host cluster.
- The Infrakube CRDs are static, so they must be installed on every workload cluster where users will create `Terraform` or `Tofu` resources.

## Prerequisites

- Infrakube installed in the host cluster.
- Network connectivity from the Infrakube controller Pod to every workload cluster API server.
- A complete kubeconfig for each workload cluster.
- RBAC in each workload cluster for the kubeconfig identity.
- A task-image pull path that works from every workload cluster.

If the task Pods use the controller cache, `--cache-url` must point at an endpoint reachable from workload clusters. For kind or isolated clusters, either expose the cache service across clusters or set `--cache-url=` and rely on direct binary downloads or bundled binaries.

## Enable Multicluster Mode

Start the controller with:

```bash
--enable-multicluster=true
```

The cluster discovery flags are:

| Flag | Default | Description |
| --- | --- | --- |
| `--enable-multicluster` | `false` | Enables kubeconfig Secret discovery and MCR watches. |
| `--cluster-secrets-namespace` | `infrakube-system` | Host-cluster namespace containing workload cluster kubeconfig Secrets. |
| `--cluster-secrets-label` | `infrakube.galleybytes.com/cluster` | Boolean label used to select cluster Secrets. |
| `--cluster-secrets-key` | `kubeconfig` | Secret data key containing kubeconfig bytes. |
| `--cluster-name-label` | `infrakube.galleybytes.com/cluster-name` | Optional Secret label that sets the logical cluster name. |

The static deployment manifest includes these flags disabled by default. To enable with `kubectl`:

```bash
kubectl -n infrakube-system patch deployment infrakube --type=json -p='[
  {"op":"replace","path":"/spec/template/spec/containers/0/args/5","value":"--enable-multicluster=true"}
]'
```

## Register Workload Clusters

Create a Secret in the host cluster for each workload cluster:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: workload-east
  namespace: infrakube-system
  labels:
    infrakube.galleybytes.com/cluster: "true"
    infrakube.galleybytes.com/cluster-name: workload-east
type: Opaque
stringData:
  kubeconfig: |-
    apiVersion: v1
    kind: Config
    current-context: workload-east
    clusters:
    - name: workload-east
      cluster:
        server: https://workload-east-api.example.com:6443
        certificate-authority-data: <base64-ca>
    contexts:
    - name: workload-east
      context:
        cluster: workload-east
        user: infrakube
    users:
    - name: infrakube
      user:
        token: <token>
```

The kubeconfig must be self-contained. Do not reference local certificate files that only exist on an operator workstation.

## Install CRDs On Workload Clusters

Install Infrakube CRDs in every cluster where `Terraform` or `Tofu` resources will be created:

```bash
kubectl --context=workload-east apply -f deploy/crds/
kubectl --context=workload-east wait --for=condition=Established crd/terraforms.infrakube.galleybytes.com --timeout=120s
kubectl --context=workload-east wait --for=condition=Established crd/tofus.infrakube.galleybytes.com --timeout=120s
```

Unlike kro, Infrakube does not generate instance CRDs dynamically from ResourceGraphDefinitions. The remote requirement is therefore static CRD installation, not dynamic CRD sync.

## Configure Workload Cluster RBAC

The kubeconfig identity must be able to watch and update `Terraform` and `Tofu` resources and manage the child resources Infrakube creates. A permissive development setup can use:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: infrakube
  namespace: infrakube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: infrakube-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: infrakube
  namespace: infrakube-system
```

For production, replace `cluster-admin` with a narrower role that covers Infrakube CRDs, Pods, Jobs, PVCs, Secrets, ConfigMaps, Events, ServiceAccounts, and any resources Terraform/OpenTofu modules create through in-cluster credentials.

## Create Remote Resources

After the workload cluster is registered and its CRDs are installed, apply resources to that workload cluster:

```bash
kubectl --context=workload-east apply -f terraform.yaml
kubectl --context=workload-east get terraform -A
```

Infrakube will:

1. receive the remote watch event through MCR,
2. reconcile with the workload cluster client,
3. create task resources in the workload cluster,
4. write status back to the workload cluster resource.

## Remove A Workload Cluster

Delete the cluster Secret from the host cluster:

```bash
kubectl -n infrakube-system delete secret workload-east
```

The controller stops watching that workload cluster. Existing remote resources remain in place, but they are no longer reconciled by the host controller.

## Local Kind Test

The multicluster smoke test in `test/e2e/multicluster` creates one host kind cluster and two workload kind clusters, registers the workloads through Secrets, deploys the controller with multicluster mode enabled, and verifies one Terraform workflow and one Tofu workflow on remote clusters.

```bash
make test-e2e-multicluster
```

See `test/e2e/multicluster/README.md` for details.

