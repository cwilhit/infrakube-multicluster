#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

HOST_CLUSTER="${HOST_CLUSTER:-infrakube-host}"
CONSUMER_CLUSTERS="${CONSUMER_CLUSTERS:-infrakube-consumer-1 infrakube-consumer-2}"

read -r -a CONSUMER_CLUSTER_ARRAY <<< "${CONSUMER_CLUSTERS}"

if [[ "${#CONSUMER_CLUSTER_ARRAY[@]}" -eq 0 ]]; then
  echo "CONSUMER_CLUSTERS must contain at least one cluster name" >&2
  exit 1
fi

require_bin() {
  local bin="$1"
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "Required command not found: ${bin}" >&2
    exit 1
  fi
}

kind_context() {
  printf "kind-%s" "$1"
}

ensure_cluster() {
  local cluster="$1"
  if kind get clusters | grep -qx "${cluster}"; then
    echo "kind cluster already exists: ${cluster}"
    return
  fi

  echo "Creating kind cluster: ${cluster}"
  kind create cluster --name "${cluster}"
}

install_crds() {
  local cluster="$1"
  local context
  context="$(kind_context "${cluster}")"

  echo "Installing Infrakube CRDs on ${cluster}"
  kubectl --context="${context}" apply -f deploy/crds/
  kubectl --context="${context}" wait --for=condition=Established crd/terraforms.infrakube.galleybytes.com --timeout=120s
  kubectl --context="${context}" wait --for=condition=Established crd/tofus.infrakube.galleybytes.com --timeout=120s
}

register_cluster() {
  local cluster="$1"
  local host_context
  local tmpdir
  local kubeconfig
  local container_ip

  host_context="$(kind_context "${HOST_CLUSTER}")"
  tmpdir="$(mktemp -d)"
  kubeconfig="${tmpdir}/${cluster}.kubeconfig"

  kind get kubeconfig --name="${cluster}" > "${kubeconfig}"
  container_ip="$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${cluster}-control-plane")"
  sed -i.bak -E "s|server: https://127.0.0.1:[0-9]+|server: https://${container_ip}:6443|g" "${kubeconfig}"

  echo "Registering workload cluster ${cluster} in ${HOST_CLUSTER}"
  kubectl --context="${host_context}" -n infrakube-system create secret generic "${cluster}" \
    --from-file=kubeconfig="${kubeconfig}" \
    --dry-run=client -o yaml | kubectl --context="${host_context}" apply -f -

  kubectl --context="${host_context}" -n infrakube-system label secret "${cluster}" \
    infrakube.galleybytes.com/cluster=true \
    infrakube.galleybytes.com/cluster-name="${cluster}" \
    --overwrite

  rm -rf "${tmpdir}"
}

require_bin docker
require_bin kind
require_bin kubectl

ensure_cluster "${HOST_CLUSTER}"
for cluster in "${CONSUMER_CLUSTER_ARRAY[@]}"; do
  ensure_cluster "${cluster}"
done

host_context="$(kind_context "${HOST_CLUSTER}")"
kubectl --context="${host_context}" apply -f deploy/namespace.yaml

install_crds "${HOST_CLUSTER}"
for cluster in "${CONSUMER_CLUSTER_ARRAY[@]}"; do
  install_crds "${cluster}"
  register_cluster "${cluster}"
done

echo "Multicluster kind setup complete."

