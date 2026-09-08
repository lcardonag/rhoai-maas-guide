#!/usr/bin/env bash
# Standalone entry point for Phase 12 OpenMeter billing.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/setup-maas.sh" --from-phase 12 --with-openmeter-billing "$@"
