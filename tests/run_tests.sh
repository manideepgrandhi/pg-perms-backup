#!/usr/bin/env bash
# Runs the test suite against a throwaway PostgreSQL cluster.
#   PG_BINDIR=/usr/lib/postgresql/17/bin tests/run_tests.sh
# Never points at an existing server: it creates, uses and deletes its own.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PG_BINDIR=${PG_BINDIR:-$(pg_config --bindir)}
for tool in initdb pg_ctl postgres; do
  [[ -x "$PG_BINDIR/$tool" ]] || { echo "Missing $PG_BINDIR/$tool: install the PostgreSQL server or set PG_BINDIR" >&2; exit 1; }
done
for tool in psql python3; do
  command -v "$tool" >/dev/null || { echo "$tool not found" >&2; exit 1; }
done
# pg_dump/pg_restore: the server's own if present, else the ones on PATH
for tool in pg_dump pg_restore; do
  [[ -x "$PG_BINDIR/$tool" ]] || command -v "$tool" >/dev/null || { echo "$tool not found" >&2; exit 1; }
done

PORT=${PPB_TEST_PORT:-55433}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/pg-perms-backup-test.XXXXXX")
cleanup() {
  "$PG_BINDIR/pg_ctl" -D "$TMP/data" -m immediate stop >/dev/null 2>&1 || true
  rm -rf -- "$TMP"
}
trap cleanup EXIT

"$PG_BINDIR/initdb" -D "$TMP/data" -U postgres --no-locale -E UTF8 \
  --auth-local=trust --auth-host=reject >"$TMP/initdb.log"
"$PG_BINDIR/pg_ctl" -D "$TMP/data" -l "$TMP/server.log" -w \
  -o "-k '$TMP' -p $PORT -c listen_addresses=''" start >/dev/null

export PGHOST="$TMP" PGPORT="$PORT" PGUSER=postgres PGDATABASE=postgres PGTZ=UTC
unset PGHOSTADDR PGSERVICE PGSERVICEFILE PGOPTIONS PGPASSWORD
export PPB_ISOLATED_TEST_CLUSTER=1 PPB_ROOT="$ROOT" PPB_WORK="$TMP" PG_BINDIR

psql -X -At -c 'SELECT version()'
python3 "$ROOT/tests/test_backup.py" -v "$@"
