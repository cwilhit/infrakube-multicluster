#!/bin/bash
set -euo pipefail

# entrypoint-wrapper.sh
#
# Wraps the compiled C++ entrypoint. For terraform tasks, extracts the
# requested terraform version before handing off to the main entrypoint.

TASK="${INFRAKUBE_TASK:-}"

case "${TASK}" in
    init|init-delete|plan|plan-delete|apply|apply-delete)
        /opt/terraform/extract-terraform.sh
        ;;
esac

exec /usr/local/bin/entrypoint-bin "$@"
