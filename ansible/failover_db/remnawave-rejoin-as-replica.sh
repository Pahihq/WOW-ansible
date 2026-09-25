#!/usr/bin/env bash
set -euo pipefail

COMPOSE_DIR="${COMPOSE_DIR:-/opt/remnawave}"
DB_SERVICE="${DB_SERVICE:-remnawave-db}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:18.4}"
PG_MAJOR="${PG_MAJOR:-18}"
PGDATA_DIR="${PGDATA_DIR:-/var/lib/postgresql/${PG_MAJOR}/docker}"
VOLUME_NAME="${VOLUME_NAME:-remnawave-db-data}"
NEW_PRIMARY_IP="${NEW_PRIMARY_IP:-10.66.66.2}"
NEW_PRIMARY_PORT="${NEW_PRIMARY_PORT:-6767}"
REPL_USER="${REPL_USER:-replicator}"
SLOT_NAME="${SLOT_NAME:-remnawave_replica_10_66_66_1}"
EXPECTED_LOCAL_IP="${EXPECTED_LOCAL_IP:-}"
CONFIRM_DESTROY_VOLUME="${CONFIRM_DESTROY_VOLUME:-}"

if [ "${CONFIRM_REJOIN:-}" != "YES" ]; then
  cat >&2 <<EOF
Refusing to continue.

This script destroys local PostgreSQL volume "$VOLUME_NAME" and rebuilds it
as a replica from ${NEW_PRIMARY_IP}:${NEW_PRIMARY_PORT}.

Run with:
  CONFIRM_REJOIN=YES REPL_PASSWORD='...' NEW_PRIMARY_IP='$NEW_PRIMARY_IP' $0
EOF
  exit 1
fi

if [ "$CONFIRM_DESTROY_VOLUME" != "$VOLUME_NAME" ]; then
  cat >&2 <<EOF
Refusing to destroy volume.

To confirm destructive rejoin, set:
  CONFIRM_DESTROY_VOLUME='$VOLUME_NAME'
EOF
  exit 1
fi

if [ -z "${REPL_PASSWORD:-}" ]; then
  echo "REPL_PASSWORD is required." >&2
  exit 1
fi

cd "$COMPOSE_DIR"

if [ -n "$EXPECTED_LOCAL_IP" ]; then
  if ! ip -o addr show | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$EXPECTED_LOCAL_IP"; then
    echo "Expected local IP $EXPECTED_LOCAL_IP was not found on this host." >&2
    echo "Refusing to rebuild the wrong server." >&2
    exit 1
  fi
fi

echo "Stopping local Remnawave stack..."
docker compose down --remove-orphans

if docker ps -a --format '{{.Names}}' | grep -Fxq "$DB_SERVICE"; then
  echo "Removing leftover $DB_SERVICE container..."
  docker rm -f "$DB_SERVICE"
fi

if docker volume inspect "$VOLUME_NAME" >/dev/null 2>&1; then
  echo "Removing old local PostgreSQL volume: $VOLUME_NAME"
  docker volume rm "$VOLUME_NAME"
fi

echo "Creating fresh local PostgreSQL volume: $VOLUME_NAME"
docker volume create "$VOLUME_NAME" >/dev/null

echo "Taking base backup from ${NEW_PRIMARY_IP}:${NEW_PRIMARY_PORT}..."
docker run --rm \
  --network host \
  -e PGPASSWORD="$REPL_PASSWORD" \
  -v "${VOLUME_NAME}:/var/lib/postgresql" \
  "$POSTGRES_IMAGE" \
  bash -lc "
    set -euo pipefail
    rm -rf '$PGDATA_DIR'
    mkdir -p '$PGDATA_DIR'
    chown -R postgres:postgres /var/lib/postgresql
    gosu postgres pg_basebackup \
      -h '$NEW_PRIMARY_IP' \
      -p '$NEW_PRIMARY_PORT' \
      -U '$REPL_USER' \
      -D '$PGDATA_DIR' \
      -Fp -Xs -P -R \
      -C -S '$SLOT_NAME'
  "

echo "Starting local PostgreSQL replica..."
docker compose up -d "$DB_SERVICE"
docker compose ps "$DB_SERVICE"

echo "Checking recovery state..."
for _ in $(seq 1 30); do
  if docker compose exec -T "$DB_SERVICE" sh -lc \
    'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "select pg_is_in_recovery();"' \
    | grep -Fxq t; then
    echo "Replica is running and pg_is_in_recovery() = true."
    exit 0
  fi
  sleep 2
done

echo "Replica did not report recovery mode in time. Check logs:" >&2
echo "  cd $COMPOSE_DIR && docker compose logs --tail=200 $DB_SERVICE" >&2
exit 1
