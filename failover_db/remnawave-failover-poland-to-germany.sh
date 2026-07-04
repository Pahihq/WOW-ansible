#!/usr/bin/env bash
set -euo pipefail

# Run on germany-back-panel / 10.66.66.1 when poland-panel-rezerv / 10.66.66.2 is down.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

COMPOSE_DIR="${COMPOSE_DIR:-/opt/remnawave}" \
START_APP="${START_APP:-true}" \
EXPECTED_LOCAL_IP="${EXPECTED_LOCAL_IP:-10.66.66.1}" \
CONFIRM_FAILOVER="${CONFIRM_FAILOVER:-}" \
"$SCRIPT_DIR/remnawave-promote-standby.sh"

cat <<'EOF'

Germany is primary now.
Next steps:
  1. Switch DNS/proxy/traffic from 10.66.66.2 to 10.66.66.1.
  2. Do not start the old Poland primary when it returns.
  3. Rejoin Poland with remnawave-rejoin-poland-as-replica.sh.
EOF
