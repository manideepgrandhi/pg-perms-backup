#!/usr/bin/env bash
# pg-perms-backup: save the permissions of one PostgreSQL database to a
# replayable SQL file before you restore over it, then put them back with
#   psql -X -d <db> -f <file>
#
# Read-only against the database: every catalog query runs in one
# READ ONLY, REPEATABLE READ transaction. Needs only psql.
set -euo pipefail

VERSION=1.0.0
PROG=$(basename -- "$0")

usage() {
  cat <<EOF
Usage: $PROG [connection options] [options]

Saves database, schema, object, column and default privileges (and,
optionally, role memberships) of one database to a replayable SQL file.

Connection options (same meaning as psql; PG* environment variables work too):
  -h, --host HOST          server host or socket directory
  -p, --port PORT          server port
  -d, --dbname DB          database to back up (the restore destination)
  -U, --username USER      user to connect as

Options:
  -o, --output FILE        output file (default: perms_<db>_<YYYYmmdd_HHMMSS>.sql)
  -s, --schema LIST        only these schemas; comma list, repeatable
                           (database-level rows are always included; global
                           default privileges only without --schema)
      --roles              also save role memberships (GRANT role TO role)
      --dry-run            print what would be saved (counts only), write nothing
  -f, --force              overwrite FILE if it exists
      --help               show this help
      --version            show the version

Replay after the restore (one transaction; missing objects and roles are
skipped and listed at the end):
  psql -X -h HOST -U USER -d DB -f FILE
EOF
}

die() { echo "$PROG: $*" >&2; exit 2; }

conn=()
output=''
schemas=()
roles=off
dry_run=0
force=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--host)     [[ $# -ge 2 ]] || die "$1 needs a value"; conn+=(-h "$2"); host=$2; shift 2 ;;
    -p|--port)     [[ $# -ge 2 ]] || die "$1 needs a value"; conn+=(-p "$2"); port=$2; shift 2 ;;
    -d|--dbname)   [[ $# -ge 2 ]] || die "$1 needs a value"; conn+=(-d "$2"); shift 2 ;;
    -U|--username) [[ $# -ge 2 ]] || die "$1 needs a value"; conn+=(-U "$2"); shift 2 ;;
    -o|--output)   [[ $# -ge 2 ]] || die "$1 needs a value"; output=$2; shift 2 ;;
    -s|--schema)   [[ $# -ge 2 ]] || die "$1 needs a value"
                   IFS=',' read -r -a _parts <<<"$2"
                   for _p in ${_parts[@]+"${_parts[@]}"}; do
                     _p=${_p#"${_p%%[![:space:]]*}"}; _p=${_p%"${_p##*[![:space:]]}"}
                     [[ -n $_p ]] && schemas+=("$_p")
                   done
                   shift 2 ;;
    --roles)       roles=on; shift ;;
    --dry-run)     dry_run=1; shift ;;
    -f|--force)    force=1; shift ;;
    --help)        usage; exit 0 ;;
    --version)     echo "pg-perms-backup $VERSION"; exit 0 ;;
    *)             usage >&2; die "unknown option: $1" ;;
  esac
done

command -v psql >/dev/null || die "psql not found in PATH"

US=$'\x1f'
RS=$'\x1e'
# -X: ignore ~/.psqlrc so its settings cannot change the output.
PSQL=(psql -X -q -At -v ON_ERROR_STOP=1 ${conn[@]+"${conn[@]}"})

# Schema names travel as one psql variable, separated by a newline (a
# character that is all but impossible in a schema name).
schema_list=''
if [[ ${#schemas[@]} -gt 0 ]]; then
  schema_list=$(printf '%s\n' "${schemas[@]}")
  schema_list=${schema_list%$'\n'}
fi

meta=$("${PSQL[@]}" -F "$US" -c "SELECT current_database(), current_user, current_setting('server_version'), current_setting('server_version_num')::int, to_char(clock_timestamp(), 'YYYY-MM-DD HH24:MI:SS TZ'), to_char(clock_timestamp(), 'YYYYMMDD_HH24MISS')") \
  || die "could not connect (check -h/-p/-d/-U, PGPASSWORD or ~/.pgpass)"
IFS="$US" read -r db_name db_user server_version server_num taken_at stamp <<<"$meta"
[[ $server_num -ge 100000 ]] || die "PostgreSQL 10 or later is required (server is $server_version)"

if [[ $server_num -ge 160000 ]]; then
  inherit_expr='bool_or(am.inherit_option)'
  set_expr='bool_or(am.set_option)'
else
  inherit_expr='NULL::boolean'
  set_expr='NULL::boolean'
fi

if [[ ${#schemas[@]} -gt 0 ]]; then
  missing=$("${PSQL[@]}" -v schemas="$schema_list" <<'SQL'
SELECT s FROM unnest(string_to_array(:'schemas', E'\n')) s
WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_namespace n WHERE n.nspname = s);
SQL
)
  if [[ -n $missing ]]; then
    echo "$PROG: warning: schema(s) not found in $db_name: $(echo "$missing" | paste -sd, -)" >&2
  fi
fi

# ---------------------------------------------------------------------------
# Generator: one row per block, "section US objects US statements US text".
# ---------------------------------------------------------------------------
read -r -d '' GENERATOR <<'SQL' || true
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL search_path = pg_catalog;

WITH RECURSIVE params AS (
  SELECT CASE WHEN :'schemas' = '' THEN NULL
              ELSE string_to_array(:'schemas', E'\n') END AS schemas,
         :'roles' = 'on' AS want_roles
),
-- AWS-internal users (rdsadmin, rdsrepladmin, rdstopmgr, ...) cannot be
-- granted to or own anything you create; rds_* group roles are kept.
rolenames AS (
  SELECT oid, rolname, quote_ident(rolname) AS qname,
         (rolname ~ '^rds' AND rolname !~ '^rds_') AS internal
  FROM pg_roles
),
nsp AS (
  SELECT n.oid, n.nspname, n.nspowner, n.nspacl
  FROM pg_namespace n, params p
  WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
    AND n.nspname !~ '^pg_(toast_)?temp_'
    AND (p.schemas IS NULL OR n.nspname = ANY (p.schemas))
),
-- Every object whose ACL and owner we save.
objs AS (
  -- database
  SELECT 2 AS sec, 'database'::text AS section, '0'::text AS sortkey,
         'DATABASE'::text AS kind, 'DATABASE'::text AS gkind,
         quote_ident(d.datname) AS ident, d.datdba AS owner, true AS set_owner,
         coalesce(d.datacl, acldefault('d', d.datdba)) AS acl, NULL::oid AS relid
  FROM pg_database d WHERE d.datname = current_database()
  UNION ALL
  -- schemas
  SELECT 3, 'schemas', n.nspname, 'SCHEMA', 'SCHEMA', quote_ident(n.nspname),
         n.nspowner, true, coalesce(n.nspacl, acldefault('n', n.nspowner)), NULL
  FROM nsp n
  UNION ALL
  -- tables, views, materialized views, foreign tables, sequences
  SELECT 4, 'objects',
         n.nspname || E'\x01' || CASE c.relkind WHEN 'S' THEN '2' WHEN 'r' THEN '0' WHEN 'p' THEN '0' ELSE '1' END || c.relname,
         CASE c.relkind WHEN 'r' THEN 'TABLE' WHEN 'p' THEN 'TABLE' WHEN 'v' THEN 'VIEW'
                        WHEN 'm' THEN 'MATERIALIZED VIEW' WHEN 'f' THEN 'FOREIGN TABLE'
                        WHEN 'S' THEN 'SEQUENCE' END,
         CASE c.relkind WHEN 'S' THEN 'SEQUENCE' ELSE 'TABLE' END,
         format('%I.%I', n.nspname, c.relname), c.relowner,
         -- owned (serial/identity) sequences follow their table's owner;
         -- extension members keep the extension's owner
         NOT EXISTS (SELECT 1 FROM pg_depend dep
                     WHERE dep.classid = 'pg_class'::regclass AND dep.objid = c.oid
                       AND (dep.deptype = 'e'
                            OR (c.relkind = 'S' AND dep.deptype IN ('a', 'i')
                                AND dep.refclassid = 'pg_class'::regclass))),
         coalesce(c.relacl, acldefault(CASE c.relkind WHEN 'S' THEN 's'::"char" ELSE 'r'::"char" END, c.relowner)),
         c.oid
  FROM pg_class c JOIN nsp n ON n.oid = c.relnamespace
  WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')
  UNION ALL
  -- functions, procedures, aggregates
  SELECT 5, 'objects', n.nspname || E'\x01' || p.oid::regprocedure::text,
         CASE p.prokind WHEN 'p' THEN 'PROCEDURE' WHEN 'a' THEN 'AGGREGATE' ELSE 'FUNCTION' END,
         CASE p.prokind WHEN 'p' THEN 'PROCEDURE' ELSE 'FUNCTION' END,
         p.oid::regprocedure::text, p.proowner,
         NOT EXISTS (SELECT 1 FROM pg_depend dep
                     WHERE dep.classid = 'pg_proc'::regclass AND dep.objid = p.oid AND dep.deptype = 'e'),
         coalesce(p.proacl, acldefault('f', p.proowner)), NULL
  FROM pg_proc p JOIN nsp n ON n.oid = p.pronamespace
  UNION ALL
  -- types and domains (not array, multirange or table row types)
  SELECT 6, 'objects', n.nspname || E'\x01' || t.typname,
         CASE t.typtype WHEN 'd' THEN 'DOMAIN' ELSE 'TYPE' END,
         CASE t.typtype WHEN 'd' THEN 'DOMAIN' ELSE 'TYPE' END,
         format_type(t.oid, NULL), t.typowner,
         NOT EXISTS (SELECT 1 FROM pg_depend dep
                     WHERE dep.classid = 'pg_type'::regclass AND dep.objid = t.oid AND dep.deptype = 'e'),
         coalesce(t.typacl, acldefault('T', t.typowner)), NULL
  FROM pg_type t JOIN nsp n ON n.oid = t.typnamespace
  WHERE t.typtype IN ('b', 'c', 'd', 'e', 'r')
    AND (t.typrelid = 0 OR (SELECT c.relkind FROM pg_class c WHERE c.oid = t.typrelid) = 'c')
    AND NOT EXISTS (SELECT 1 FROM pg_type e WHERE e.typarray = t.oid)
),
kept AS (
  SELECT o.*, ro.qname AS owner_q, ro.rolname AS owner_name
  FROM objs o JOIN rolenames ro ON ro.oid = o.owner
  WHERE NOT ro.internal
),
grants AS (
  SELECT k.sec, k.sortkey, k.kind, k.ident, a.grantee, a.grantor, a.is_grantable,
         string_agg(a.privilege_type, ', ' ORDER BY a.privilege_type) AS privs,
         (a.grantor <> k.owner) AS foreign_grantor
  FROM kept k, aclexplode(k.acl) a
  GROUP BY 1, 2, 3, 4, 5, 6, 7, k.owner
),
-- Grants made by non-owners must be replayed after the grant that gave the
-- grantor its grant option: order them by their distance from the owner.
fg_objs AS (
  SELECT k.* FROM kept k
  WHERE EXISTS (SELECT 1 FROM aclexplode(k.acl) a WHERE a.grantor <> k.owner)
),
chain (sec, sortkey, kind, ident, role, depth) AS (
  SELECT f.sec, f.sortkey, f.kind, f.ident, f.owner, 0 FROM fg_objs f
  UNION ALL
  SELECT c.sec, c.sortkey, c.kind, c.ident, a.grantee, c.depth + 1
  FROM chain c
  JOIN fg_objs f ON f.sec = c.sec AND f.sortkey = c.sortkey AND f.kind = c.kind AND f.ident = c.ident
  CROSS JOIN LATERAL aclexplode(f.acl) a
  WHERE a.grantor = c.role AND a.is_grantable AND a.grantee <> 0 AND a.grantee <> f.owner AND c.depth < 32
),
gdepth AS (
  SELECT sec, sortkey, kind, ident, role, min(depth) AS depth FROM chain GROUP BY 1, 2, 3, 4, 5
),
grant_lines AS (
  SELECT g.sec, g.sortkey, g.kind, g.ident,
         string_agg(
           format('CALL pg_temp.ppb_run(%L, %L%s);  -- by %s',
                  g.kind || ' ' || g.ident,
                  format('GRANT %s ON %s %s TO %s%s', g.privs,
                         CASE WHEN g.kind IN ('VIEW', 'MATERIALIZED VIEW', 'FOREIGN TABLE') THEN 'TABLE'
                              WHEN g.kind = 'AGGREGATE' THEN 'FUNCTION' ELSE g.kind END,
                         g.ident,
                         CASE WHEN g.grantee = 0 THEN 'PUBLIC' ELSE rg.qname END,
                         CASE WHEN g.is_grantable THEN ' WITH GRANT OPTION' ELSE '' END),
                  CASE WHEN g.foreign_grantor THEN format(', %L', rr.qname) ELSE '' END,
                  rr.rolname),
           E'\n' ORDER BY g.foreign_grantor, coalesce(gd.depth, 0), rr.rolname,
                          CASE WHEN g.grantee = 0 THEN '' ELSE rg.rolname END, g.is_grantable) AS lines,
         count(*) AS n
  FROM grants g
  LEFT JOIN rolenames rg ON rg.oid = g.grantee
  JOIN rolenames rr ON rr.oid = g.grantor
  LEFT JOIN gdepth gd ON gd.sec = g.sec AND gd.sortkey = g.sortkey AND gd.kind = g.kind
                     AND gd.ident = g.ident AND gd.role = g.grantor
  WHERE (g.grantee = 0 OR NOT rg.internal) AND NOT rr.internal
  GROUP BY 1, 2, 3, 4
),
-- column privileges, one statement per grantee/grantor/grant option
col_privs AS (
  SELECT k.sec, k.sortkey, k.kind, k.ident, k.owner, a.grantee, a.grantor, a.is_grantable,
         a.privilege_type,
         string_agg(quote_ident(att.attname), ', ' ORDER BY att.attnum) AS cols
  FROM kept k
  JOIN pg_attribute att ON att.attrelid = k.relid AND att.attnum > 0
                       AND NOT att.attisdropped AND att.attacl IS NOT NULL
  CROSS JOIN LATERAL aclexplode(att.attacl) a
  GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9
),
col_grants AS (
  SELECT c.sec, c.sortkey, c.kind, c.ident, c.grantee, c.grantor, c.is_grantable,
         (c.grantor <> c.owner) AS foreign_grantor,
         string_agg(format('%s (%s)', c.privilege_type, c.cols), ', ' ORDER BY c.privilege_type) AS privs
  FROM col_privs c
  GROUP BY 1, 2, 3, 4, 5, 6, 7, 8
),
col_lines AS (
  SELECT g.sec, g.sortkey, g.kind, g.ident,
         string_agg(
           format('CALL pg_temp.ppb_run(%L, %L%s);  -- column grant by %s',
                  g.kind || ' ' || g.ident,
                  format('GRANT %s ON TABLE %s TO %s%s', g.privs, g.ident,
                         CASE WHEN g.grantee = 0 THEN 'PUBLIC' ELSE rg.qname END,
                         CASE WHEN g.is_grantable THEN ' WITH GRANT OPTION' ELSE '' END),
                  CASE WHEN g.foreign_grantor THEN format(', %L', rr.qname) ELSE '' END,
                  rr.rolname),
           E'\n' ORDER BY g.foreign_grantor, rr.rolname, CASE WHEN g.grantee = 0 THEN '' ELSE rg.rolname END,
                          g.is_grantable) AS lines,
         count(*) AS n
  FROM col_grants g
  LEFT JOIN rolenames rg ON rg.oid = g.grantee
  JOIN rolenames rr ON rr.oid = g.grantor
  WHERE (g.grantee = 0 OR NOT rg.internal) AND NOT rr.internal
  GROUP BY 1, 2, 3, 4
),
db_settings AS (
  SELECT s.setrole, cfg,
         split_part(cfg, '=', 1) AS name,
         substr(cfg, strpos(cfg, '=') + 1) AS value
  FROM pg_db_role_setting s
  JOIN pg_database d ON d.oid = s.setdatabase AND d.datname = current_database()
  CROSS JOIN LATERAL unnest(s.setconfig) AS cfg
  LEFT JOIN rolenames r ON r.oid = s.setrole
  WHERE s.setrole = 0 OR NOT r.internal
),
settings_block AS (
  SELECT 2 AS sec, 'database'::text AS section, '1'::text AS sortkey,
         concat_ws(E'\n',
           '-- database and role-in-database settings (ALTER DATABASE / ALTER ROLE ... SET)',
           'CALL pg_temp.ppb_reset_settings();',
           string_agg(
             format('CALL pg_temp.ppb_run(%L, %L);',
                    'DATABASE ' || quote_ident(current_database()) || ' settings',
                    format('ALTER %s SET %s = %s',
                           CASE WHEN s.setrole = 0 THEN 'DATABASE ' || quote_ident(current_database())
                                ELSE 'ROLE ' || quote_ident(pg_get_userbyid(s.setrole))
                                     || ' IN DATABASE ' || quote_ident(current_database()) END,
                           quote_ident(s.name),
                           -- list settings are stored already quoted (pg_dump does the same)
                           CASE WHEN lower(s.name) IN ('search_path', 'temp_tablespaces',
                                     'session_preload_libraries', 'local_preload_libraries',
                                     'shared_preload_libraries')
                                THEN s.value ELSE quote_literal(s.value) END)),
             E'\n' ORDER BY s.setrole <> 0, pg_get_userbyid(s.setrole), s.name)) AS block,
         0 AS nobj, count(s.cfg) AS n
  FROM (SELECT 1) one LEFT JOIN db_settings s ON true
),
object_blocks AS (
  SELECT k.sec, k.section, k.sortkey,
         concat_ws(E'\n',
           format('-- %s %s, owner %s', k.kind, k.ident, k.owner_name),
           format('CALL pg_temp.ppb_object(%L, %L, %s);', k.kind, k.ident,
                  CASE WHEN k.set_owner THEN quote_literal(k.owner_q) ELSE 'NULL' END),
           gl.lines, cl.lines) AS block,
         1 AS nobj,
         (CASE WHEN k.set_owner THEN 1 ELSE 0 END) + coalesce(gl.n, 0) + coalesce(cl.n, 0) AS n
  FROM kept k
  LEFT JOIN grant_lines gl ON gl.sec = k.sec AND gl.sortkey = k.sortkey AND gl.kind = k.kind AND gl.ident = k.ident
  LEFT JOIN col_lines cl ON cl.sec = k.sec AND cl.sortkey = k.sortkey AND cl.kind = k.kind AND cl.ident = k.ident
),
defacl AS (
  SELECT d.defaclrole, d.defaclnamespace, d.defaclobjtype, d.defaclacl,
         r.qname AS role_q, n.nspname
  FROM pg_default_acl d
  JOIN rolenames r ON r.oid = d.defaclrole AND NOT r.internal
  LEFT JOIN pg_namespace n ON n.oid = d.defaclnamespace,
  params p
  WHERE (d.defaclnamespace = 0 AND p.schemas IS NULL)
     OR (d.defaclnamespace <> 0 AND n.nspname IN (SELECT nspname FROM nsp))
),
defacl_stmts AS (
  -- global entries replace the built-in defaults, so start from nothing
  SELECT d.role_q, d.nspname, d.defaclobjtype, 0 AS ord, NULL::text AS grantee_name,
         format('ALTER DEFAULT PRIVILEGES FOR ROLE %s REVOKE ALL ON %s FROM %s', d.role_q,
                CASE d.defaclobjtype WHEN 'r' THEN 'TABLES' WHEN 'S' THEN 'SEQUENCES'
                     WHEN 'f' THEN 'FUNCTIONS' WHEN 'T' THEN 'TYPES' WHEN 'n' THEN 'SCHEMAS' END,
                who) AS stmt
  FROM defacl d CROSS JOIN LATERAL (VALUES ('PUBLIC'), (d.role_q)) w(who)
  WHERE d.defaclnamespace = 0
  UNION ALL
  SELECT d.role_q, d.nspname, d.defaclobjtype, 1, CASE WHEN a.grantee = 0 THEN '' ELSE rg.rolname END,
         format('ALTER DEFAULT PRIVILEGES FOR ROLE %s%s GRANT %s ON %s TO %s%s', d.role_q,
                CASE WHEN d.defaclnamespace <> 0 THEN ' IN SCHEMA ' || quote_ident(d.nspname) ELSE '' END,
                string_agg(a.privilege_type, ', ' ORDER BY a.privilege_type),
                CASE d.defaclobjtype WHEN 'r' THEN 'TABLES' WHEN 'S' THEN 'SEQUENCES'
                     WHEN 'f' THEN 'FUNCTIONS' WHEN 'T' THEN 'TYPES' WHEN 'n' THEN 'SCHEMAS' END,
                CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE rg.qname END,
                CASE WHEN a.is_grantable THEN ' WITH GRANT OPTION' ELSE '' END)
  FROM defacl d
  CROSS JOIN LATERAL aclexplode(d.defaclacl) a
  LEFT JOIN rolenames rg ON rg.oid = a.grantee
  WHERE a.grantee = 0 OR NOT rg.internal
  GROUP BY d.role_q, d.nspname, d.defaclnamespace, d.defaclobjtype, a.grantee, rg.rolname, rg.qname, a.is_grantable
),
defacl_block AS (
  SELECT 7 AS sec, 'default privileges'::text AS section, ''::text AS sortkey,
         concat_ws(E'\n',
           '-- default privileges (ALTER DEFAULT PRIVILEGES)',
           format('CALL pg_temp.ppb_reset_default_privileges(%s, %s);',
                  CASE WHEN p.schemas IS NULL THEN 'NULL'
                       ELSE quote_literal((SELECT coalesce(array_agg(nspname ORDER BY nspname), '{}') FROM nsp)::text) || '::text[]' END,
                  CASE WHEN p.schemas IS NULL THEN 'true' ELSE 'false' END),
           (SELECT string_agg(format('CALL pg_temp.ppb_run(%L, %L);',
                                     'DEFAULT PRIVILEGES FOR ROLE ' || s.role_q
                                       || coalesce(' IN SCHEMA ' || quote_ident(s.nspname), ''),
                                     s.stmt),
                              E'\n' ORDER BY s.role_q, s.nspname NULLS FIRST, s.defaclobjtype, s.ord, s.grantee_name, s.stmt COLLATE "C")
            FROM defacl_stmts s)) AS block,
         0 AS nobj, (SELECT count(*) FROM defacl_stmts) AS n
  FROM params p
),
memberships AS (
  SELECT r.rolname AS role_name, m.rolname AS member_name,
         bool_or(am.admin_option) AS admin_opt,
         :inherit_expr AS inherit_opt,
         :set_expr AS set_opt,
         string_agg(DISTINCT g.rolname, ', ') AS grantors
  FROM pg_auth_members am
  JOIN pg_roles r ON r.oid = am.roleid
  JOIN pg_roles m ON m.oid = am.member
  LEFT JOIN pg_roles g ON g.oid = am.grantor
  WHERE m.rolname !~ '^(pg_|rds)'          -- built-in and AWS-managed members
    AND NOT (r.rolname ~ '^rds' AND r.rolname !~ '^rds_')
  GROUP BY 1, 2
),
roles_block AS (
  SELECT 1 AS sec, 'roles'::text AS section, ''::text AS sortkey,
         concat_ws(E'\n',
           '-- role memberships (additive: existing memberships are not revoked)',
           string_agg(
             format('CALL pg_temp.ppb_run(%L, %L);  -- granted by %s',
                    'ROLE ' || quote_ident(m.member_name),
                    format('GRANT %s TO %s%s', quote_ident(m.role_name), quote_ident(m.member_name),
                           CASE WHEN m.inherit_opt IS NOT NULL
                                THEN format(' WITH ADMIN %s, INHERIT %s, SET %s',
                                            upper(m.admin_opt::text), upper(m.inherit_opt::text),
                                            upper(m.set_opt::text))
                                WHEN m.admin_opt THEN ' WITH ADMIN OPTION' ELSE '' END),
                    coalesce(m.grantors, '?')),
             E'\n' ORDER BY m.member_name, m.role_name)) AS block,
         0 AS nobj, count(m.role_name) AS n
  FROM params p LEFT JOIN memberships m ON true
  WHERE p.want_roles
  GROUP BY p.want_roles
)
SELECT section, nobj, n, block
FROM (
  SELECT sec, section, sortkey, block, nobj, n FROM roles_block
  UNION ALL SELECT sec, section, sortkey, block, nobj, n FROM object_blocks
  UNION ALL SELECT sec, section, sortkey, block, nobj, n FROM settings_block
  UNION ALL SELECT sec, section, sortkey, block, nobj, n FROM defacl_block
) b
ORDER BY sec, sortkey COLLATE "C", block COLLATE "C";

COMMIT;
SQL

tmp=$(mktemp "${TMPDIR:-/tmp}/pg-perms-backup.XXXXXX")
trap 'rm -f -- "$tmp" "$tmp.body"' EXIT

"${PSQL[@]}" -F "$US" -R "$RS" \
  -v schemas="$schema_list" -v roles="$roles" \
  -v inherit_expr="$inherit_expr" -v set_expr="$set_expr" \
  -f - <<<"$GENERATOR" >"$tmp.body" \
  || die "reading the catalogs failed (see the psql error above)"

if [[ $dry_run -eq 1 ]]; then
  echo "pg-perms-backup $VERSION dry run: $db_name on ${host:-${PGHOST:-local socket}} (PostgreSQL $server_version)"
  [[ ${#schemas[@]} -gt 0 ]] && echo "schemas: $(IFS=,; echo "${schemas[*]}")"
  awk -v RS="$RS" -v FS="$US" '
    NF >= 3 { objs[$1] += $2; stmts[$1] += $3; if (!($1 in seen)) { seen[$1] = 1; order[++k] = $1 } }
    END {
      printf "%-20s %8s %11s\n", "section", "objects", "statements"
      for (i = 1; i <= k; i++) { s = order[i]; printf "%-20s %8d %11d\n", s, objs[s], stmts[s]; to += objs[s]; ts += stmts[s] }
      printf "%-20s %8d %11d\n", "total", to, ts
    }' "$tmp.body"
  echo "nothing written (dry run)"
  exit 0
fi

[[ -n $output ]] || output="perms_${db_name//[^A-Za-z0-9_.-]/_}_${stamp}.sql"
if [[ -e $output && $force -ne 1 ]]; then
  die "$output already exists (use -f/--force to overwrite)"
fi

db_lit=${db_name//\'/\'\'}
{
  cat <<EOF
-- pg-perms-backup $VERSION
-- Source:   host=${host:-${PGHOST:-local socket}} port=${port:-${PGPORT:-5432}} database=$db_name user=$db_user
-- Server:   PostgreSQL $server_version
-- Taken:    $taken_at
-- Schemas:  $( [[ ${#schemas[@]} -gt 0 ]] && (IFS=,; echo "${schemas[*]}") || echo "all")
-- Roles:    $( [[ $roles == on ]] && echo "memberships included" || echo "not included (use --roles)")
--
-- Replay after the restore, connected to the same database as its owner,
-- a superuser or (on RDS/Aurora) the master user:
--   psql -X -h <host> -U <user> -d $db_name -f <this file>
-- Everything runs in one transaction. A statement whose object or role no
-- longer exists is skipped and listed at the end instead of stopping the run.
-- For each saved object, all current privileges are revoked first and the
-- saved ones granted, so the result matches this file exactly.

\\set ON_ERROR_STOP on
\\set QUIET on
\\pset pager off
SET client_min_messages = error;
BEGIN;
SET LOCAL search_path = pg_catalog;

DO \$guard\$
BEGIN
  IF current_database() <> '$db_lit' THEN
    RAISE EXCEPTION 'this file was taken from database "%", but you are connected to "%"', '$db_lit', current_database()
      USING HINT = 'Connect to the database the file was taken from (psql -d $db_lit).';
  END IF;
END
\$guard\$;
EOF
  cat <<'EOF'

-- Replay helpers (temporary: they disappear when the session ends).
CREATE TEMP TABLE ppb_log (id bigserial, object text, statement text, status text, reason text);
CREATE TEMP TABLE ppb_missing (object text PRIMARY KEY);
CREATE TEMP TABLE ppb_pending (id bigserial, object text, statement text, grantor text);

CREATE FUNCTION pg_temp.ppb_lookup(p_kind text, p_ident text,
    OUT objid oid, OUT owner oid, OUT acl aclitem[], OUT col_grantees oid[])
LANGUAGE plpgsql AS $f$
DECLARE v_relkind "char";
BEGIN
  IF p_kind = 'DATABASE' THEN
    SELECT d.oid, d.datdba, coalesce(d.datacl, acldefault('d', d.datdba))
      INTO objid, owner, acl FROM pg_database d
     WHERE d.datname = current_database() AND quote_ident(d.datname) = p_ident;
  ELSIF p_kind = 'SCHEMA' THEN
    SELECT n.oid, n.nspowner, coalesce(n.nspacl, acldefault('n', n.nspowner))
      INTO objid, owner, acl FROM pg_namespace n WHERE n.oid = to_regnamespace(p_ident);
  ELSIF p_kind IN ('TABLE', 'VIEW', 'MATERIALIZED VIEW', 'FOREIGN TABLE', 'SEQUENCE') THEN
    SELECT c.oid, c.relowner,
           coalesce(c.relacl, acldefault(CASE c.relkind WHEN 'S' THEN 's'::"char" ELSE 'r'::"char" END, c.relowner)),
           c.relkind
      INTO objid, owner, acl, v_relkind FROM pg_class c WHERE c.oid = to_regclass(p_ident);
    IF objid IS NOT NULL AND v_relkind <> ALL (CASE p_kind
         WHEN 'TABLE' THEN '{r,p}' WHEN 'VIEW' THEN '{v}' WHEN 'MATERIALIZED VIEW' THEN '{m}'
         WHEN 'FOREIGN TABLE' THEN '{f}' ELSE '{S}' END::"char"[]) THEN
      objid := NULL;   -- same name, different kind of object
    END IF;
    IF objid IS NOT NULL THEN
      SELECT array_agg(DISTINCT a.grantee) INTO col_grantees
        FROM pg_attribute att, aclexplode(att.attacl) a
       WHERE att.attrelid = objid AND att.attnum > 0 AND att.attacl IS NOT NULL;
    END IF;
  ELSIF p_kind IN ('FUNCTION', 'PROCEDURE', 'AGGREGATE') THEN
    SELECT p.oid, p.proowner, coalesce(p.proacl, acldefault('f', p.proowner))
      INTO objid, owner, acl FROM pg_proc p WHERE p.oid = to_regprocedure(p_ident);
  ELSIF p_kind IN ('TYPE', 'DOMAIN') THEN
    SELECT t.oid, t.typowner, coalesce(t.typacl, acldefault('T', t.typowner))
      INTO objid, owner, acl FROM pg_type t WHERE t.oid = to_regtype(p_ident);
  END IF;
EXCEPTION WHEN OTHERS THEN   -- e.g. a type in a function signature no longer exists
  objid := NULL;
END
$f$;

-- Set the saved owner and revoke every current privilege on one object.
CREATE PROCEDURE pg_temp.ppb_object(p_kind text, p_ident text, p_owner text)
LANGUAGE plpgsql AS $f$
DECLARE
  v_key text := p_kind || ' ' || p_ident;
  v_gkind text := CASE WHEN p_kind IN ('VIEW', 'MATERIALIZED VIEW', 'FOREIGN TABLE') THEN 'TABLE'
                       WHEN p_kind = 'AGGREGATE' THEN 'FUNCTION' ELSE p_kind END;
  o record;
  v_owner_ok boolean := true;
  v_new_owner oid;
  v_sql text;
  v_g oid;
BEGIN
  o := pg_temp.ppb_lookup(p_kind, p_ident);
  IF o.objid IS NULL THEN
    INSERT INTO ppb_missing VALUES (v_key) ON CONFLICT DO NOTHING;
    INSERT INTO ppb_log (object, status, reason) VALUES (v_key, 'missing', 'object not found');
    RETURN;
  END IF;
  INSERT INTO ppb_log (object, status) VALUES (v_key, 'object');

  IF p_owner IS NOT NULL THEN
    BEGIN
      v_new_owner := to_regrole(p_owner);
    EXCEPTION WHEN OTHERS THEN v_new_owner := NULL;
    END;
    IF v_new_owner IS NULL THEN
      v_owner_ok := false;
      INSERT INTO ppb_log (object, statement, status, reason)
      VALUES (v_key, format('ALTER %s %s OWNER TO %s', p_kind, p_ident, p_owner), 'skipped',
              format('owner role %s not found; current owner kept', p_owner));
    ELSIF v_new_owner <> o.owner THEN
      v_sql := format('ALTER %s %s OWNER TO %s', p_kind, p_ident, p_owner);
      BEGIN
        EXECUTE v_sql;
        INSERT INTO ppb_log (object, statement, status) VALUES (v_key, v_sql, 'applied');
      EXCEPTION WHEN OTHERS THEN
        v_owner_ok := false;
        INSERT INTO ppb_log (object, statement, status, reason) VALUES (v_key, v_sql, 'skipped', SQLERRM);
      END;
      o := pg_temp.ppb_lookup(p_kind, p_ident);   -- the owner change rewrote the ACL
    END IF;
  END IF;

  -- Revoke from everyone, PUBLIC and the owner included (the owner's own
  -- privileges are re-granted from the saved ACL right after). CASCADE also
  -- removes grants made by holders of a grant option.
  FOR v_g IN SELECT DISTINCT g FROM (
      SELECT a.grantee AS g FROM aclexplode(o.acl) a
      UNION SELECT unnest(o.col_grantees)) s
  LOOP
    CONTINUE WHEN v_g = o.owner AND NOT v_owner_ok;
    v_sql := format('REVOKE ALL ON %s %s FROM %s CASCADE', v_gkind, p_ident,
                    CASE WHEN v_g = 0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(v_g)) END);
    BEGIN
      EXECUTE v_sql;
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO ppb_log (object, statement, status, reason) VALUES (v_key, v_sql, 'skipped', SQLERRM);
    END;
  END LOOP;
END
$f$;

-- Run one statement; p_grantor runs it as the role that granted it originally.
CREATE PROCEDURE pg_temp.ppb_run(p_object text, p_sql text, p_grantor text DEFAULT NULL)
LANGUAGE plpgsql AS $f$
DECLARE v_me text := current_user;
BEGIN
  IF EXISTS (SELECT 1 FROM ppb_missing WHERE object = p_object) THEN
    INSERT INTO ppb_log (object, statement, status, reason)
    VALUES (p_object, p_sql, 'not run', 'object not found');
    RETURN;
  END IF;
  BEGIN
    IF p_grantor IS NOT NULL THEN
      EXECUTE format('SET LOCAL ROLE %s', p_grantor);
    END IF;
    EXECUTE p_sql;
    IF p_grantor IS NOT NULL THEN
      EXECUTE format('SET LOCAL ROLE %I', v_me);
    END IF;
    INSERT INTO ppb_log (object, statement, status) VALUES (p_object, p_sql, 'applied');
  EXCEPTION WHEN OTHERS THEN
    IF p_grantor IS NOT NULL THEN   -- the grantor may get its grant option later
      INSERT INTO ppb_pending (object, statement, grantor) VALUES (p_object, p_sql, p_grantor);
    ELSE
      INSERT INTO ppb_log (object, statement, status, reason) VALUES (p_object, p_sql, 'skipped', SQLERRM);
    END IF;
  END;
END
$f$;

-- Retry grants made by non-owners until nothing changes; then grant the rest
-- as the current user (the grantor changes) or report them.
CREATE PROCEDURE pg_temp.ppb_finish_pending()
LANGUAGE plpgsql AS $f$
DECLARE r record; v_progress boolean := true; v_me text := current_user;
BEGIN
  WHILE v_progress LOOP
    v_progress := false;
    FOR r IN SELECT * FROM ppb_pending ORDER BY id LOOP
      BEGIN
        EXECUTE format('SET LOCAL ROLE %s', r.grantor);
        EXECUTE r.statement;
        EXECUTE format('SET LOCAL ROLE %I', v_me);
        DELETE FROM ppb_pending WHERE id = r.id;
        INSERT INTO ppb_log (object, statement, status) VALUES (r.object, r.statement, 'applied');
        v_progress := true;
      EXCEPTION WHEN OTHERS THEN NULL;
      END;
    END LOOP;
  END LOOP;
  FOR r IN SELECT * FROM ppb_pending ORDER BY id LOOP
    BEGIN
      EXECUTE r.statement;
      INSERT INTO ppb_log (object, statement, status, reason)
      VALUES (r.object, r.statement, 'grantor changed',
              format('could not grant as %s; granted as %s instead', r.grantor, v_me));
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO ppb_log (object, statement, status, reason) VALUES (r.object, r.statement, 'skipped', SQLERRM);
    END;
  END LOOP;
  DELETE FROM ppb_pending;
END
$f$;

-- Remove the current database-wide and role-in-database settings.
CREATE PROCEDURE pg_temp.ppb_reset_settings()
LANGUAGE plpgsql AS $f$
DECLARE r record; v_sql text;
BEGIN
  FOR r IN SELECT s.setrole FROM pg_db_role_setting s JOIN pg_database d ON d.oid = s.setdatabase
            WHERE d.datname = current_database() LOOP
    v_sql := CASE WHEN r.setrole = 0
                  THEN format('ALTER DATABASE %I RESET ALL', current_database())
                  ELSE format('ALTER ROLE %I IN DATABASE %I RESET ALL', pg_get_userbyid(r.setrole), current_database()) END;
    BEGIN
      EXECUTE v_sql;
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO ppb_log (object, statement, status, reason)
      VALUES ('DATABASE ' || quote_ident(current_database()) || ' settings', v_sql, 'skipped', SQLERRM);
    END;
  END LOOP;
END
$f$;

-- Put the default privileges in scope back to the built-in defaults.
CREATE PROCEDURE pg_temp.ppb_reset_default_privileges(p_schemas text[], p_global boolean)
LANGUAGE plpgsql AS $f$
DECLARE r record; v_sql text; v_word text; v_prefix text; v_g oid;
BEGIN
  FOR r IN SELECT d.defaclrole, d.defaclnamespace, d.defaclobjtype, d.defaclacl, n.nspname
             FROM pg_default_acl d LEFT JOIN pg_namespace n ON n.oid = d.defaclnamespace
            WHERE (d.defaclnamespace = 0 AND p_global)
               OR (d.defaclnamespace <> 0 AND (p_schemas IS NULL OR n.nspname = ANY (p_schemas)))
  LOOP
    v_word := CASE r.defaclobjtype WHEN 'r' THEN 'TABLES' WHEN 'S' THEN 'SEQUENCES'
                   WHEN 'f' THEN 'FUNCTIONS' WHEN 'T' THEN 'TYPES' WHEN 'n' THEN 'SCHEMAS' END;
    v_prefix := format('ALTER DEFAULT PRIVILEGES FOR ROLE %I', pg_get_userbyid(r.defaclrole))
                || CASE WHEN r.defaclnamespace <> 0 THEN format(' IN SCHEMA %I', r.nspname) ELSE '' END;
    FOR v_g IN SELECT DISTINCT a.grantee FROM aclexplode(r.defaclacl) a LOOP
      v_sql := format('%s REVOKE ALL ON %s FROM %s', v_prefix, v_word,
                      CASE WHEN v_g = 0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(v_g)) END);
      BEGIN
        EXECUTE v_sql;
      EXCEPTION WHEN OTHERS THEN
        INSERT INTO ppb_log (object, statement, status, reason) VALUES ('DEFAULT PRIVILEGES', v_sql, 'skipped', SQLERRM);
      END;
    END LOOP;
    IF r.defaclnamespace = 0 THEN   -- built-in defaults: owner has all, PUBLIC may run functions and use types
      BEGIN
        EXECUTE format('%s GRANT ALL ON %s TO %I', v_prefix, v_word, pg_get_userbyid(r.defaclrole));
        IF r.defaclobjtype IN ('f', 'T') THEN
          EXECUTE format('%s GRANT ALL ON %s TO PUBLIC', v_prefix, v_word);
        END IF;
      EXCEPTION WHEN OTHERS THEN
        INSERT INTO ppb_log (object, statement, status, reason)
        VALUES ('DEFAULT PRIVILEGES', v_prefix || ' (reset to defaults)', 'skipped', SQLERRM);
      END;
    END IF;
  END LOOP;
END
$f$;

EOF
  awk -v RS="$RS" -v FS="$US" 'NF >= 4 { print ""; print $4 }' "$tmp.body"
  cat <<'EOF'

CALL pg_temp.ppb_finish_pending();

-- Summary
\set QUIET off
\echo
\echo 'pg-perms-backup replay summary'
SELECT CASE status WHEN 'object' THEN 'objects found' WHEN 'missing' THEN 'objects missing'
                   ELSE 'statements ' || status END AS result,
       count(*) AS count
FROM ppb_log GROUP BY status
ORDER BY min(CASE status WHEN 'object' THEN 1 WHEN 'applied' THEN 2 WHEN 'grantor changed' THEN 3
                         WHEN 'missing' THEN 4 WHEN 'not run' THEN 5 ELSE 6 END);
\echo 'Missing objects, skipped and changed statements (empty when everything applied):'
SELECT status, object, coalesce(statement, '') AS statement, reason
FROM ppb_log WHERE status IN ('missing', 'skipped', 'grantor changed') ORDER BY id;
\set QUIET on
COMMIT;
EOF
} >"$tmp"

mv -f -- "$tmp" "$output"
chmod 0600 "$output" 2>/dev/null || true
summary=$(awk -v RS="$RS" -v FS="$US" 'NF >= 3 { o += $2; s += $3 } END { printf "%d objects, %d statements", o, s }' "$tmp.body")
echo "Saved permissions of $db_name ($summary) to $output"
