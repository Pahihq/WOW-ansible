#!/usr/bin/env bash
set -euo pipefail

# Run on poland-panel-rezerv / 10.66.66.2 when germany-back-panel / 10.66.66.1 is down.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

COMPOSE_DIR="${COMPOSE_DIR:-/opt/remnawave}" \
START_APP="${START_APP:-true}" \
EXPECTED_LOCAL_IP="${EXPECTED_LOCAL_IP:-10.66.66.2}" \
CONFIRM_FAILOVER="${CONFIRM_FAILOVER:-}" \
"$SCRIPT_DIR/remnawave-promote-standby.sh"

cat <<'EOF'

Poland is primary now.
Next steps:
  1. Switch DNS/proxy/traffic from 10.66.66.1 to 10.66.66.2.
  2. Do not start the old Germany primary when it returns.
  3. Rejoin Germany with remnawave-rejoin-germany-as-replica.sh.
EOF
