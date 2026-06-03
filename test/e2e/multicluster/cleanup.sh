#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

HOST_CLUSTER="${HOST_CLUSTER:-infrakube-host}"
CONSUMER_CLUSTERS="${CONSUMER_CLUSTERS:-infrakube-consumer-1 infrakube-consumer-2}"

read -r -a CONSUMER_CLUSTER_ARRAY <<< "${CONSUMER_CLUSTERS}"

delete_cluster() {
  local cluster="$1"
  if kind get clusters | grep -qx "${cluster}"; then
    echo "Deleting kind cluster: ${cluster}"
    kind delete cluster --name "${cluster}"
  else
    echo "kind cluster not found: ${cluster}"
  fi
}

for cluster in "${CONSUMER_CLUSTER_ARRAY[@]}"; do
  delete_cluster "${cluster}"
done
delete_cluster "${HOST_CLUSTER}"

echo "Multicluster kind cleanup complete."

