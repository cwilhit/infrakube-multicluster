#!/bin/bash
set -euo pipefail

# extract-terraform.sh
#
# Terraform binary resolution tiers:
# 1. Bundled xz archive in the image
# 2. Controller cache (HTTP GET)
# 3. User-provided INFRAKUBE_TF_DOWNLOAD_URL override (always available)
# 4. Auto-download from INFRAKUBE_TF_DOWNLOAD_URL_BASE (gated by INFRAKUBE_AUTO_DOWNLOAD)
# 5. Fail with helpful error

VERSION="${INFRAKUBE_TF_VERSION:-latest}"
VERSIONS_DIR="/opt/terraform/versions"
BIN_DIR="/opt/terraform/bin"
TERRAFORM_BIN="${BIN_DIR}/terraform"
CACHE_URL="${INFRAKUBE_CACHE_URL:-}"
AUTO_DOWNLOAD="${INFRAKUBE_AUTO_DOWNLOAD:-true}"
DOWNLOAD_BASE_URL="${INFRAKUBE_TF_DOWNLOAD_URL_BASE:-https://releases.hashicorp.com/terraform}"
DOWNLOAD_BASE_URL="${DOWNLOAD_BASE_URL%/}"

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
    echo "Not in controller cache."
fi

TMPFILE=$(mktemp)
trap 'rm -f "${TMPFILE}"' EXIT

cache_binary() {
    if [ -n "${CACHE_URL}" ]; then
        echo "Caching terraform ${VERSION} for future runs..."
        curl -sSL -X PUT --data-binary @"${TERRAFORM_BIN}" \
            "${CACHE_URL}/api/v1/terraform/${VERSION}?arch=${ARCH}" 2>/dev/null || true
    fi
}

# Tier 3: User-provided download URL (always available, takes priority over auto-download)
if [ -n "${INFRAKUBE_TF_DOWNLOAD_URL:-}" ]; then
    echo "Downloading terraform from user-provided URL..."
    curl -sSL --fail "${INFRAKUBE_TF_DOWNLOAD_URL}" -o "${TMPFILE}"
    if [ -n "${INFRAKUBE_TF_DOWNLOAD_SHA256:-}" ]; then
        ACTUAL_SHA256=$(sha256sum "${TMPFILE}" | cut -d' ' -f1)
        if [ "${ACTUAL_SHA256}" != "${INFRAKUBE_TF_DOWNLOAD_SHA256}" ]; then
            echo "ERROR: SHA256 checksum mismatch!" >&2
            echo "  Expected: ${INFRAKUBE_TF_DOWNLOAD_SHA256}" >&2
            echo "  Got:      ${ACTUAL_SHA256}" >&2
            exit 1
        fi
    fi
    if file "${TMPFILE}" | grep -q 'Zip archive'; then
        unzip -o "${TMPFILE}" terraform -d "${BIN_DIR}"
    else
        cp "${TMPFILE}" "${TERRAFORM_BIN}"
    fi
    chmod +x "${TERRAFORM_BIN}"
    echo "Terraform ${VERSION} ready (user-provided)."
    cache_binary
    exit 0
fi

# Tier 4: Auto-download from base URL (gated by INFRAKUBE_AUTO_DOWNLOAD)
if [ "${AUTO_DOWNLOAD}" = "true" ]; then
    DOWNLOAD_URL="${DOWNLOAD_BASE_URL}/${VERSION}/terraform_${VERSION}_linux_${ARCH}.zip"
    echo "Auto-downloading terraform ${VERSION} from ${DOWNLOAD_BASE_URL}..."
    if curl -sSL --fail -o "${TMPFILE}" "${DOWNLOAD_URL}" 2>/dev/null; then
        unzip -o "${TMPFILE}" terraform -d "${BIN_DIR}"
        chmod +x "${TERRAFORM_BIN}"
        echo "Terraform ${VERSION} ready (auto-downloaded)."
        cache_binary
        exit 0
    fi
    echo "Auto-download failed for terraform ${VERSION}."
fi

# All tiers failed
AVAILABLE=$(available_versions | tr '\n' ' ')
cat >&2 <<EOF
ERROR: Terraform version '${VERSION}' is not available.

Checked: bundled image, controller cache$([ "${AUTO_DOWNLOAD}" = "true" ] && echo ", ${DOWNLOAD_BASE_URL}").

Available bundled versions: ${AVAILABLE}

To provide a custom binary, set INFRAKUBE_TF_DOWNLOAD_URL in your
Terraform resource's taskOptions:

    taskOptions:
    - for: ["init", "init-delete", "plan", "plan-delete", "apply", "apply-delete"]
      env:
      - name: INFRAKUBE_TF_DOWNLOAD_URL
        value: "https://releases.hashicorp.com/terraform/${VERSION}/terraform_${VERSION}_linux_amd64.zip"
EOF
exit 1
