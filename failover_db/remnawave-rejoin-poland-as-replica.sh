#!/usr/bin/env bash
set -euo pipefail

# Run on poland-panel-rezerv / 10.66.66.2 after Germany / 10.66.66.1 was promoted.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

CONFIRM_REJOIN="${CONFIRM_REJOIN:-}" \
REPL_PASSWORD="${REPL_PASSWORD:-}" \
CONFIRM_DESTROY_VOLUME="${CONFIRM_DESTROY_VOLUME:-}" \
EXPECTED_LOCAL_IP="${EXPECTED_LOCAL_IP:-10.66.66.2}" \
NEW_PRIMARY_IP="${NEW_PRIMARY_IP:-10.66.66.1}" \
NEW_PRIMARY_PORT="${NEW_PRIMARY_PORT:-5432}" \
SLOT_NAME="${SLOT_NAME:-remnawave_replica_10_66_66_2}" \
"$SCRIPT_DIR/remnawave-rejoin-as-replica.sh"

cat <<'EOF'

Poland is a standby replica now.
Keep only remnawave-db running on Poland until you intentionally fail back.
EOF
