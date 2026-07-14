#!/usr/bin/env bash
# =====================================================================
# Re-apply volumes/db/init.sql against an ALREADY-INITIALIZED supabase-db.
# ---------------------------------------------------------------------
# The official postgres image only runs /docker-entrypoint-initdb.d/*
# once, the first time it boots against an empty data directory
# (./volumes/db/data). Any init.sql edit made after that first boot
# never reaches an existing install on its own -- `docker compose up`
# / `restart` will NOT re-run it. This script replays init.sql by hand
# against the live database so schema/function/trigger changes land
# without wiping ./volumes/db/data (which would drop all data).
#
# Precondition: init.sql must stay safe to re-run end-to-end --
# CREATE OR REPLACE FUNCTION, CREATE TABLE/INDEX IF NOT EXISTS, and
# DROP TRIGGER IF EXISTS immediately before every CREATE TRIGGER. This
# script does not add idempotency on its own; it just replays the file.
#
# Usage: ./scripts/migrate-db.sh
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

ENV_FILE="./.env"
[ -f "$ENV_FILE" ] || { echo "ERROR: .env not found." >&2; exit 1; }

if ! docker ps --format '{{.Names}}' | grep -qx supabase-db; then
    echo "ERROR: supabase-db is not running. Start the infra stack first (./start-all-services.sh)." >&2
    exit 1
fi

PGPW=$(grep -E '^POSTGRES_PASSWORD=' "$ENV_FILE" | cut -d= -f2-)

echo ">>> Replaying volumes/db/init.sql against the running supabase-db..."
docker exec -e PGPASSWORD="$PGPW" supabase-db psql -U supabase_admin -d postgres \
    -v ON_ERROR_STOP=1 \
    -f /docker-entrypoint-initdb.d/init-scripts/100-init.sql
echo ">>> Done. Schema/function/trigger changes in init.sql are now applied."
