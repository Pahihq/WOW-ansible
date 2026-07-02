#!/usr/bin/env bash
set -euo pipefail

COMPOSE_DIR="${COMPOSE_DIR:-/opt/remnawave}"
DB_SERVICE="${DB_SERVICE:-remnawave-db}"
APP_SERVICE="${APP_SERVICE:-remnawave}"
START_APP="${START_APP:-true}"
EXPECTED_LOCAL_IP="${EXPECTED_LOCAL_IP:-}"
CONFIRM_FAILOVER="${CONFIRM_FAILOVER:-}"

if [ "$CONFIRM_FAILOVER" != "PROMOTE" ]; then
  cat >&2 <<EOF
Refusing to promote standby.

This action makes the local PostgreSQL node writable primary and may cause
split-brain if the old primary is still running.

Run with:
  CONFIRM_FAILOVER=PROMOTE $0
EOF
  exit 1
fi

cd "$COMPOSE_DIR"

if [ -n "$EXPECTED_LOCAL_IP" ]; then
  if ! ip -o addr show | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$EXPECTED_LOCAL_IP"; then
    echo "Expected local IP $EXPECTED_LOCAL_IP was not found on this host." >&2
    echo "Refusing to promote the wrong server." >&2
    exit 1
  fi
fi

echo "Checking PostgreSQL recovery state on $(hostname)..."
in_recovery="$(
  docker compose exec -T "$DB_SERVICE" sh -lc \
    'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "select pg_is_in_recovery();"'
)"

if [ "$in_recovery" = "f" ]; then
  echo "This node is already primary. Nothing to promote."
else
  if [ "$in_recovery" != "t" ]; then
    echo "Unexpected pg_is_in_recovery() result: $in_recovery" >&2
    exit 1
  fi

  echo "Promoting standby to primary..."
  docker compose exec -T "$DB_SERVICE" sh -lc \
    'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "select pg_promote(true);"'

  new_state="$(
    docker compose exec -T "$DB_SERVICE" sh -lc \
      'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "select pg_is_in_recovery();"'
  )"

  if [ "$new_state" != "f" ]; then
    echo "Promotion did not complete. pg_is_in_recovery() returned: $new_state" >&2
    exit 1
  fi
fi

if [ "$START_APP" = "true" ]; then
  echo "Starting Remnawave stack on the promoted primary..."
  docker compose up -d
  docker compose ps
else
  echo "START_APP=false, leaving application services unchanged."
fi

echo "Failover promotion complete. This node is primary now."
