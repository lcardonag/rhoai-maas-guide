#!/usr/bin/env bash
# Standalone entry point for Phase 11 Lago billing (same as setup-maas.sh --with-lago-billing).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/setup-maas.sh" --from-phase 11 --with-lago-billing "$@"
