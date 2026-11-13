# pg-perms-backup

Save the permissions of a PostgreSQL database before you restore over it, and
put them back afterwards.

Refreshing dev from prod with `pg_dump` and `pg_restore` usually loses the
destination's own grants: the restore brings prod's grants (or none, with
`--no-acl`), prod's owners (or the restoring user, with `--no-owner`), and
drops database-level grants and settings when the database is recreated.
`pg-perms-backup.sh` reads the destination's catalogs **before** the restore
and writes one SQL file that sets everything back **after** it.

- One Bash script. It needs only `psql`, no extension and nothing installed in
  the database.
- Read-only: every catalog query runs in a single `READ ONLY`, `REPEATABLE
  READ` transaction, so the file is one consistent snapshot.
- The replay is one transaction. Objects or roles that no longer exist are
  skipped and listed at the end instead of stopping the run.
- The replay revokes first, so the result matches the saved state exactly,
  not "saved grants plus whatever the restore brought".
- Tested on PostgreSQL 14, 15, 16 and 17. Written with RDS and Aurora
  PostgreSQL in mind (see [RDS and Aurora](#rds-and-aurora)).

## What it saves

| Level | Saved |
|---|---|
| Database | owner; `CONNECT`, `CREATE`, `TEMPORARY` grants; `ALTER DATABASE ... SET` and `ALTER ROLE ... IN DATABASE ... SET` settings |
| Schema | owner; `USAGE`, `CREATE` grants |
| Object | owner and grants on tables, partitioned tables and partitions, views, materialized views, foreign tables, sequences, functions, procedures, aggregates, types and domains |
| Column | column-level grants such as `GRANT SELECT (id, name)` |
| Default privileges | every `ALTER DEFAULT PRIVILEGES [FOR ROLE ...] [IN SCHEMA ...]` rule |
| Roles (`--roles`) | role memberships (`GRANT role TO role`), with `ADMIN`, and on PostgreSQL 16+ `INHERIT` and `SET` options |

`WITH GRANT OPTION` is kept. The role that made each grant is written as a
comment, and grants made by a non-owner (someone holding a grant option) are
replayed as that role so the grantor is kept too.

Skipped: `pg_catalog`, `information_schema`, `pg_toast` and temporary
schemas; AWS-internal users (`rdsadmin`, `rdsrepladmin`, `rdstopmgr`, any
name starting with `rds` but not `rds_`) as owners or grantees; and objects
they own. Grants to `rds_*` group roles and to predefined `pg_*` roles are
kept, because those roles exist on the destination.

## Requirements

- Bash 4 or later with `awk`, `mktemp` and `paste` (Linux, macOS with a newer
  Bash, WSL, or Git Bash on Windows).
- `psql` on `PATH`, any version from 10 on.
- To back up: a role that can read the catalogs (any role can). To replay: the
  database owner and object owners' privileges, so a superuser or, on RDS and
  Aurora, the master user.

## Quick start

```bash
# 1. Before the restore: back up the destination's permissions
./pg-perms-backup.sh -h dev-host -d appdb -U dba -o perms_appdb_20261113.sql

# 2. Restore (see the walkthrough for flags)

# 3. After the restore: put the permissions back
psql -X -h dev-host -U dba -d appdb -f perms_appdb_20261113.sql
```

## Options

| Option | Meaning |
|---|---|
| `-h, --host HOST` | server host or socket directory |
| `-p, --port PORT` | server port |
| `-d, --dbname DB` | database to back up (the restore destination) |
| `-U, --username USER` | user to connect as |
| `-o, --output FILE` | output file; default `perms_<db>_<YYYYmmdd_HHMMSS>.sql` |
| `-s, --schema LIST` | only these schemas; comma list, repeatable (`-s billing,hr -s audit`) |
| `--roles` | also save role memberships |
| `--dry-run` | print counts per section, write nothing |
| `-f, --force` | overwrite the output file if it exists |
| `--help`, `--version` | |

Passwords come from `PGPASSWORD` or `~/.pgpass`, as with psql, and the other
`PG*` environment variables work too. The script never stores a password in
the file.

`--schema` limits the schema, object and default-privilege sections to those
schemas. Database-level grants and settings are always included. Global
default privileges (`ALTER DEFAULT PRIVILEGES` without `IN SCHEMA`) are only
included without `--schema`. A schema that doesn't exist gives a warning.

## Full walkthrough: refresh dev from prod and keep dev's permissions

The example refreshes `appdb` on `dev-host` from `prod-host`.

### 1. Back up the destination's permissions

```bash
./pg-perms-backup.sh -h dev-host -U dba -d appdb --dry-run          # see what will be saved
./pg-perms-backup.sh -h dev-host -U dba -d appdb --roles \
    -o perms_appdb_20261113.sql
```

Keep the file. It's plain SQL, so you can read it, diff it with an older one
or put it in version control. Use `--roles` if the role memberships on dev
might also change (for example if you also apply a `pg_dumpall --roles-only`
from prod).

### 2. Dump the source

```bash
pg_dump -h prod-host -U dba -d appdb -Fc -f appdb_prod.dump
```

Use the custom (`-Fc`) or directory (`-Fd`) format so you can pick restore
flags later. `pg_dump` never dumps roles, so roles that exist only in prod
will be missing on dev.

### 3. Restore at the destination

Either recreate the database:

```bash
psql -h dev-host -U dba -d postgres -c 'DROP DATABASE appdb WITH (FORCE)'   # PG13+
psql -h dev-host -U dba -d postgres -c 'CREATE DATABASE appdb'
pg_restore -h dev-host -U dba -d appdb --no-owner --no-acl -j 4 appdb_prod.dump
```

or restore over it in place:

```bash
pg_restore -h dev-host -U dba -d appdb --clean --if-exists \
    --no-owner --no-acl -j 4 appdb_prod.dump
```

Flag advice:

- `--no-acl` (same as `--no-privileges`): skip prod's grants. Not required,
  because the replay revokes first, but it avoids errors for prod-only roles
  and makes the restore log quieter.
- `--no-owner`: objects are owned by the restoring user instead of prod's
  owners. Use it when prod's owners don't exist on dev. The replay sets the
  saved owners back.
- `--create` recreates the database with prod's database-level grants and
  settings; the replay replaces them with dev's. Without `--create`, the
  database-level permissions of a recreated database are the defaults, and the
  replay sets dev's back.
- `-j N` restores in parallel (custom or directory format only).
- Don't use `--single-transaction` with `-j`. `--exit-on-error` is useful once
  to see which statements fail.
- On RDS and Aurora, restore as the master user, and expect harmless errors
  for `rds_*`-owned objects and extensions you can't create.

### 4. Replay the permissions

```bash
psql -X -h dev-host -U dba -d appdb -f perms_appdb_20261113.sql
```

Connect to the database the file was taken from: the file refuses to run
anywhere else. Everything runs in one transaction. At the end it prints a
summary, for example:

```
pg-perms-backup replay summary
       result       | count
--------------------+-------
 objects found      |    23
 statements applied |    95
 objects missing    |     1
 statements not run |     2
(4 rows)

Missing objects, skipped and changed statements (empty when everything applied):
 status  |        object        | statement |      reason
---------+----------------------+-----------+------------------
 missing | TABLE billing.legacy |           | object not found
(1 row)
```

- `objects missing`: the object was in the backup but not in the restored
  database (for example a dev-only table). Its grants are counted as `not run`.
- `statements skipped`: a statement failed, usually because a grantee or owner
  role doesn't exist. The reason column has the error.
- `statements grantor changed`: a grant made by a non-owner couldn't be made
  as that role (for example the role is gone), so it was made as you instead.

Running the file again is safe; it converges to the same state.

### 5. Check the result

Take a second backup and compare it with the first (only the header differs
when everything came back):

```bash
./pg-perms-backup.sh -h dev-host -U dba -d appdb --roles -o perms_after.sql
diff <(grep -v '^-- ' perms_appdb_20261113.sql) <(grep -v '^-- ' perms_after.sql)
```

Or look at one role's full access with
[pg-access-inspector](https://github.com/manideepgrandhi/pg-access-inspector)'s
`access_report('<role>')`.

## How the replay works

The file starts with a guard (right database), `BEGIN`, and a few helper
procedures created in `pg_temp`, so they vanish with the session and nothing
is left behind. Then, for every saved object:

1. `pg_temp.ppb_object(kind, name, owner)` looks the object up. If it isn't
   there, it's recorded as missing and its grants are not run.
2. If the owner differs, `ALTER ... OWNER TO` the saved owner.
3. Every current privilege on the object, column privileges included, is
   revoked from every grantee (PUBLIC and the owner too) with `CASCADE`.
4. `pg_temp.ppb_run(...)` replays each saved grant, including the owner's own
   privileges, so an owner that had given up some of its own rights stays
   that way. Each statement runs in its own savepoint, so one failure doesn't
   stop the rest.

Grants made by a non-owner are run with `SET ROLE <grantor>`, ordered so the
grant that gave the grantor its grant option comes first. If that's not
possible, they're retried at the end and, as a last resort, made as the
current user and listed as `grantor changed`.

Database settings are reset (`RESET ALL` for the database and for each role in
the database) before the saved ones are set. Default privileges in scope are
put back to the built-in defaults before the saved rules are applied.

Role memberships are additive: the file grants the saved memberships but
doesn't revoke memberships added later.

## RDS and Aurora

- Run the backup as any role; run the replay as the master user (member of
  `rds_superuser`). The master user isn't a real superuser, so it can only
  change owners and run `SET ROLE` for roles it's a member of. On PostgreSQL
  16+ that isn't automatic for roles created by other users. Statements it
  can't run are listed as skipped instead of failing the replay.
- Objects owned by `rdsadmin` and grants to AWS-internal users are left out.
  Memberships of `rds_*` and `pg_*` roles themselves are left out of
  `--roles`; memberships *in* them, such as `GRANT rds_superuser TO dba`, are
  kept.

## Limitations

- Not yet tested against a real RDS or Aurora instance, only community
  PostgreSQL 14 to 17.
- Not saved: large objects, languages, foreign data wrappers and foreign
  servers, tablespaces, `GRANT ... ON PARAMETER` (PG15+), row-level security
  policies (they're part of the table definition and come with the dump), and
  role attributes or passwords.
- Objects that exist only after the restore (new in prod) are not touched;
  they keep whatever the restore gave them.
- A non-owner who runs `GRANT` without the grant option gets a warning, not an
  error, from PostgreSQL; the replay hides warnings, so such a statement would
  count as applied. Replay as the owner or a superuser to avoid this.
- The database name must match. To replay into a renamed database, replace the
  name in the file first.
- Extension member objects keep the extension's owner; only their grants are
  replayed.
- Owned sequences (`serial`, identity) follow their table's owner.

## Tests

```bash
PG_BINDIR=/usr/lib/postgresql/17/bin tests/run_tests.sh
```

The suite starts a throwaway cluster, builds a fixture with a role chain, a
NOINHERIT member, grants at every level, column grants, grant chains through
non-owners and global and per-schema default privileges, then for each case
backs up, restores a dump from a differently permissioned "prod" copy (with
and without `--no-owner --no-acl`), replays and compares every owner, ACL,
setting and membership in the catalogs with the snapshot taken before. It
also covers missing objects and roles, a missing grantor, the wrong database,
`--schema`, `--dry-run`, `--roles`, a read-only session and replaying twice.
CI runs it on PostgreSQL 14, 15, 16 and 17.

## License

MIT, see [LICENSE](LICENSE).
