#!/bin/bash
set -euo pipefail

# extract-terraform.sh
#
# Three-tier terraform binary resolution:
# 1. Bundled xz archive in the image
# 2. Controller cache (HTTP GET)
# 3. Internet download from HashiCorp (then PUT to controller cache)

VERSION="${INFRAKUBE_TF_VERSION:-latest}"
VERSIONS_DIR="/opt/terraform/versions"
BIN_DIR="/opt/terraform/bin"
TERRAFORM_BIN="${BIN_DIR}/terraform"
CACHE_URL="${INFRAKUBE_CACHE_URL:-}"

map_arch() {
    case "$(uname -m)" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        *)       echo "$(uname -m)" ;;
    esac
}

ARCH=$(map_arch)

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

# Tier 1: Try bundled xz archive
if [ -f "${VERSIONS_DIR}/${VERSION}.xz" ]; then
    echo "Extracting bundled terraform ${VERSION}..."
    xz -d -k "${VERSIONS_DIR}/${VERSION}.xz" --stdout > "${TERRAFORM_BIN}"
    chmod +x "${TERRAFORM_BIN}"
    echo "Terraform ${VERSION} ready."
    exit 0
fi

# Tier 2: Try controller cache
if [ -n "${CACHE_URL}" ]; then
    echo "Checking controller cache for terraform ${VERSION} (${ARCH})..."
    if curl -sSL --fail -o "${TERRAFORM_BIN}" "${CACHE_URL}/api/v1/terraform/${VERSION}?arch=${ARCH}" 2>/dev/null; then
        chmod +x "${TERRAFORM_BIN}"
        echo "Terraform ${VERSION} ready (from cache)."
        exit 0
    fi
    echo "Not in controller cache, trying internet download..."
fi

# Tier 3: Download from HashiCorp, then cache for future runs
DOWNLOAD_URL="https://releases.hashicorp.com/terraform/${VERSION}/terraform_${VERSION}_linux_${ARCH}.zip"
echo "Downloading terraform ${VERSION} from HashiCorp..."
TMPFILE=$(mktemp)
trap 'rm -f "${TMPFILE}"' EXIT

if curl -sSL --fail -o "${TMPFILE}" "${DOWNLOAD_URL}" 2>/dev/null; then
    unzip -o "${TMPFILE}" terraform -d "${BIN_DIR}"
    chmod +x "${TERRAFORM_BIN}"
    echo "Terraform ${VERSION} ready (downloaded)."

    # Push to controller cache for future runs
    if [ -n "${CACHE_URL}" ]; then
        echo "Caching terraform ${VERSION} for future runs..."
        curl -sSL -X PUT --data-binary @"${TERRAFORM_BIN}" \
            "${CACHE_URL}/api/v1/terraform/${VERSION}?arch=${ARCH}" 2>/dev/null || true
    fi
    exit 0
fi

# Try user-provided download URL with checksum verification
if [ -n "${INFRAKUBE_TF_DOWNLOAD_URL:-}" ] && [ -n "${INFRAKUBE_TF_DOWNLOAD_SHA256:-}" ]; then
    echo "Downloading terraform from user-provided URL..."
    curl -sSL "${INFRAKUBE_TF_DOWNLOAD_URL}" -o "${TMPFILE}"
    ACTUAL_SHA256=$(sha256sum "${TMPFILE}" | cut -d' ' -f1)
    if [ "${ACTUAL_SHA256}" != "${INFRAKUBE_TF_DOWNLOAD_SHA256}" ]; then
        echo "ERROR: SHA256 checksum mismatch!" >&2
        echo "  Expected: ${INFRAKUBE_TF_DOWNLOAD_SHA256}" >&2
        echo "  Got:      ${ACTUAL_SHA256}" >&2
        exit 1
    fi
    if file "${TMPFILE}" | grep -q 'Zip archive'; then
        unzip -o "${TMPFILE}" terraform -d "${BIN_DIR}"
    else
        cp "${TMPFILE}" "${TERRAFORM_BIN}"
    fi
    chmod +x "${TERRAFORM_BIN}"
    echo "Terraform ${VERSION} ready (user-provided)."

    # Push to controller cache for future runs
    if [ -n "${CACHE_URL}" ]; then
        curl -sSL -X PUT --data-binary @"${TERRAFORM_BIN}" \
            "${CACHE_URL}/api/v1/terraform/${VERSION}?arch=${ARCH}" 2>/dev/null || true
    fi
    exit 0
fi

# All tiers failed
AVAILABLE=$(available_versions | tr '\n' ' ')
ENCODED_VERSION=$(echo -n "${VERSION}" | sed 's/ /%20/g')
ISSUE_URL="https://github.com/galleybytes/infrakube/issues/new?title=Add%20terraform%20${ENCODED_VERSION}%20to%20bundled%20versions&body=Please%20add%20terraform%20${ENCODED_VERSION}%20to%20the%20infrakube-task%20image.%0A%0AThis%20version%20is%20available%20at%20https://releases.hashicorp.com/terraform/${ENCODED_VERSION}/"

cat >&2 <<EOF
ERROR: Terraform version '${VERSION}' is not available.

Checked: bundled image, controller cache, HashiCorp releases.

Available bundled versions: ${AVAILABLE}

To provide a custom binary, set environment variables in your
Terraform resource's taskOptions:

    taskOptions:
    - for: ["init", "init-delete", "plan", "plan-delete", "apply", "apply-delete"]
      env:
      - name: INFRAKUBE_TF_DOWNLOAD_URL
        value: "https://releases.hashicorp.com/terraform/${VERSION}/terraform_${VERSION}_linux_amd64.zip"
      - name: INFRAKUBE_TF_DOWNLOAD_SHA256
        value: "<sha256-of-the-zip-file>"

Checksums: https://releases.hashicorp.com/terraform/${VERSION}/

Request this version be added: ${ISSUE_URL}
EOF
exit 1
