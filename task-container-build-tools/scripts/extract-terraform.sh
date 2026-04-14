#!/bin/bash
set -euo pipefail

# extract-terraform.sh
#
# Extracts or downloads the requested terraform version for use in the pod.
# Called by the entrypoint wrapper before the main entrypoint for terraform tasks.

VERSION="${INFRAKUBE_TF_VERSION:-latest}"
VERSIONS_DIR="/opt/terraform/versions"
BIN_DIR="/opt/terraform/bin"
TERRAFORM_BIN="${BIN_DIR}/terraform"

available_versions() {
    ls "${VERSIONS_DIR}"/*.xz 2>/dev/null | sed 's|.*/||;s|\.xz$||' | sort -V
}

if [ "${VERSION}" = "latest" ]; then
    VERSION=$(available_versions | tail -1)
    if [ -z "${VERSION}" ]; then
        echo "ERROR: No terraform versions bundled in this image." >&2
        exit 1
    fi
    echo "Using latest bundled terraform version: ${VERSION}"
fi

# Already extracted (e.g., init container ran before plan container in same pod)
if [ -f "${TERRAFORM_BIN}" ]; then
    CURRENT=$("${TERRAFORM_BIN}" version -json 2>/dev/null | grep terraform_version | sed 's/.*: "//;s/".*//' || true)
    if [ "${CURRENT}" = "${VERSION}" ]; then
        exit 0
    fi
fi

mkdir -p "${BIN_DIR}"

# Try bundled version first
if [ -f "${VERSIONS_DIR}/${VERSION}.xz" ]; then
    echo "Extracting bundled terraform ${VERSION}..."
    xz -d -k "${VERSIONS_DIR}/${VERSION}.xz" --stdout > "${TERRAFORM_BIN}"
    chmod +x "${TERRAFORM_BIN}"
    echo "Terraform ${VERSION} ready."
    exit 0
fi

# Try user-provided download URL with checksum verification
if [ -n "${INFRAKUBE_TF_DOWNLOAD_URL:-}" ] && [ -n "${INFRAKUBE_TF_DOWNLOAD_SHA256:-}" ]; then
    echo "Downloading terraform from user-provided URL..."
    TMPFILE=$(mktemp)
    trap 'rm -f "${TMPFILE}"' EXIT
    curl -sSL "${INFRAKUBE_TF_DOWNLOAD_URL}" -o "${TMPFILE}"
    ACTUAL_SHA256=$(sha256sum "${TMPFILE}" | cut -d' ' -f1)
    if [ "${ACTUAL_SHA256}" != "${INFRAKUBE_TF_DOWNLOAD_SHA256}" ]; then
        echo "ERROR: SHA256 checksum mismatch!" >&2
        echo "  Expected: ${INFRAKUBE_TF_DOWNLOAD_SHA256}" >&2
        echo "  Got:      ${ACTUAL_SHA256}" >&2
        exit 1
    fi
    # Handle both zip files and raw binaries
    if file "${TMPFILE}" | grep -q 'Zip archive'; then
        unzip -o "${TMPFILE}" terraform -d "${BIN_DIR}"
    else
        cp "${TMPFILE}" "${TERRAFORM_BIN}"
    fi
    chmod +x "${TERRAFORM_BIN}"
    echo "Terraform ${VERSION} ready (user-provided)."
    exit 0
fi

# Version not available -- print helpful error
AVAILABLE=$(available_versions | tr '\n' ' ')
ENCODED_VERSION=$(echo -n "${VERSION}" | sed 's/ /%20/g')
ISSUE_URL="https://github.com/galleybytes/infrakube/issues/new?title=Add%20terraform%20${ENCODED_VERSION}%20to%20bundled%20versions&body=Please%20add%20terraform%20${ENCODED_VERSION}%20to%20the%20infrakube-task%20image.%0A%0AThis%20version%20is%20available%20at%20https://releases.hashicorp.com/terraform/${ENCODED_VERSION}/"

cat >&2 <<EOF
ERROR: Terraform version '${VERSION}' is not bundled in this image.

Available bundled versions: ${AVAILABLE}

To unblock yourself, provide the terraform binary via environment variables
in your Terraform resource's taskOptions:

    taskOptions:
    - for: ["init", "init-delete", "plan", "plan-delete", "apply", "apply-delete"]
      env:
      - name: INFRAKUBE_TF_DOWNLOAD_URL
        value: "https://releases.hashicorp.com/terraform/${VERSION}/terraform_${VERSION}_linux_amd64.zip"
      - name: INFRAKUBE_TF_DOWNLOAD_SHA256
        value: "<sha256-of-the-zip-file>"

You can find checksums at:
  https://releases.hashicorp.com/terraform/${VERSION}/

To request this version be added to the official image, open an issue:
  ${ISSUE_URL}
EOF
exit 1
