#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

HOST_CLUSTER="${HOST_CLUSTER:-infrakube-host}"
CONSUMER_CLUSTERS="${CONSUMER_CLUSTERS:-infrakube-consumer-1 infrakube-consumer-2}"
CONTROLLER_IMAGE="${CONTROLLER_IMAGE:-ghcr.io/galleybytes/infrakube:e2e}"
TASK_IMAGE="${TASK_IMAGE:-ghcr.io/galleybytes/infrakube-task:e2e}"

read -r -a CONSUMER_CLUSTER_ARRAY <<< "${CONSUMER_CLUSTERS}"

if [[ "${#CONSUMER_CLUSTER_ARRAY[@]}" -eq 0 ]]; then
  echo "CONSUMER_CLUSTERS must contain at least one cluster name" >&2
  exit 1
fi

TF_CLUSTER="${CONSUMER_CLUSTER_ARRAY[0]}"
TOFU_CLUSTER="${TF_CLUSTER}"
if [[ "${#CONSUMER_CLUSTER_ARRAY[@]}" -gt 1 ]]; then
  TOFU_CLUSTER="${CONSUMER_CLUSTER_ARRAY[1]}"
fi

kind_context() {
  printf "kind-%s" "$1"
}

load_image_if_present() {
  local cluster="$1"
  local image="$2"

  if docker image inspect "${image}" >/dev/null 2>&1; then
    echo "Loading ${image} into kind cluster ${cluster}"
    kind load docker-image --name "${cluster}" "${image}"
  else
    echo "Local image not found, cluster will pull if needed: ${image}"
  fi
}

wait_for_jsonpath() {
  local context="$1"
  local resource="$2"
  local jsonpath="$3"
  local expected="$4"
  local attempts="${5:-120}"

  local current=""
  for _ in $(seq 1 "${attempts}"); do
    current="$(kubectl --context="${context}" get ${resource} -o "jsonpath=${jsonpath}" 2>/dev/null || true)"
    if [[ "${current}" == "${expected}" ]]; then
      return 0
    fi
    sleep 5
  done

  echo "Timed out waiting for ${resource} in ${context} ${jsonpath} to equal ${expected}, last value was '${current}'"
  return 1
}

dump_debug() {
  echo "Collecting multicluster smoke diagnostics..."

  local host_context
  host_context="$(kind_context "${HOST_CLUSTER}")"
  kubectl --context="${host_context}" get pods --all-namespaces -o wide || true
  kubectl --context="${host_context}" -n infrakube-system get secrets -l infrakube.galleybytes.com/cluster=true || true
  kubectl --context="${host_context}" -n infrakube-system describe deployment infrakube || true
  kubectl --context="${host_context}" -n infrakube-system logs deployment/infrakube --all-containers=true || true

  for cluster in "${CONSUMER_CLUSTER_ARRAY[@]}"; do
    local context
    context="$(kind_context "${cluster}")"
    echo "Diagnostics for ${cluster}"
    kubectl --context="${context}" get pods --all-namespaces -o wide || true
    kubectl --context="${context}" get terraform --all-namespaces || true
    kubectl --context="${context}" get tofu --all-namespaces || true
    kubectl --context="${context}" -n tf-e2e describe terraform terraform-inline || true
    kubectl --context="${context}" -n tofu-e2e describe tofu tofu-inline || true
  done
}

trap dump_debug ERR

host_context="$(kind_context "${HOST_CLUSTER}")"
tf_context="$(kind_context "${TF_CLUSTER}")"
tofu_context="$(kind_context "${TOFU_CLUSTER}")"

echo "Loading local images when available..."
load_image_if_present "${HOST_CLUSTER}" "${CONTROLLER_IMAGE}"
for cluster in "${CONSUMER_CLUSTER_ARRAY[@]}"; do
  load_image_if_present "${cluster}" "${TASK_IMAGE}"
done

echo "Installing Infrakube controller into ${HOST_CLUSTER}..."
kubectl --context="${host_context}" apply -f deploy/namespace.yaml
kubectl --context="${host_context}" apply -f deploy/crds/
kubectl --context="${host_context}" wait --for=condition=Established crd/terraforms.infrakube.galleybytes.com --timeout=120s
kubectl --context="${host_context}" wait --for=condition=Established crd/tofus.infrakube.galleybytes.com --timeout=120s
kubectl --context="${host_context}" apply -f deploy/serviceaccount.yaml
kubectl --context="${host_context}" apply -f deploy/clusterrole.yaml
kubectl --context="${host_context}" apply -f deploy/clusterrolebinding.yaml
kubectl --context="${host_context}" apply -f deploy/pvc.yaml
kubectl --context="${host_context}" apply -f deploy/service.yaml
kubectl --context="${host_context}" apply -f deploy/deployment.yaml

kubectl --context="${host_context}" -n infrakube-system patch deployment infrakube --type=json -p "$(printf '[{"op":"replace","path":"/spec/template/spec/containers/0/image","value":"%s"},{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"},{"op":"replace","path":"/spec/template/spec/containers/0/args","value":["--zap-log-level=debug","--zap-encoder=console","--auto-download=true","--cache-url=","--tf-download-base-url=https://releases.hashicorp.com/terraform","--tofu-download-base-url=https://github.com/opentofu/opentofu/releases/download","--task-image=%s","--enable-multicluster=true","--cluster-secrets-namespace=infrakube-system","--cluster-secrets-label=infrakube.galleybytes.com/cluster","--cluster-secrets-key=kubeconfig","--cluster-name-label=infrakube.galleybytes.com/cluster-name"]}]' "${CONTROLLER_IMAGE}" "${TASK_IMAGE}")"
kubectl --context="${host_context}" -n infrakube-system rollout status deployment/infrakube --timeout=180s

echo "Applying Terraform fixture to ${TF_CLUSTER}..."
kubectl --context="${tf_context}" apply -f test/e2e/manifests/terraform-inline.yaml

echo "Applying Tofu fixture to ${TOFU_CLUSTER}..."
kubectl --context="${tofu_context}" apply -f test/e2e/manifests/tofu-inline.yaml

echo "Waiting for remote Terraform workflow..."
wait_for_jsonpath "${tf_context}" "terraform -n tf-e2e terraform-inline" "{.status.phase}" "completed"
wait_for_jsonpath "${tf_context}" "terraform -n tf-e2e terraform-inline" "{.status.outputs.hello}" "terraform-smoke"

echo "Waiting for remote Tofu workflow..."
wait_for_jsonpath "${tofu_context}" "tofu -n tofu-e2e tofu-inline" "{.status.phase}" "completed"
wait_for_jsonpath "${tofu_context}" "tofu -n tofu-e2e tofu-inline" "{.status.outputs.hello}" "tofu-smoke"

echo "Multicluster kind smoke test passed."

