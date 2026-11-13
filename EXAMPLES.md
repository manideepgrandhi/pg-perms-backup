# Examples

All output below comes from the test fixture on PostgreSQL 17, with host names,
user names and version strings shortened. All names are made up.

## Dry run

```
$ ./pg-perms-backup.sh -h dev-host -U dba -d appdb --roles --dry-run
pg-perms-backup 1.0.0 dry run: appdb on dev-host (PostgreSQL 17.12)
section               objects  statements
roles                       0           5
database                    1           9
schemas                     4          14
objects                    19          58
default privileges          0          13
total                      24          99
nothing written (dry run)
```

`statements` counts grants, settings, default-privilege rules, memberships and
owner checks (an owner is only changed when it differs).

## Backup

```
$ ./pg-perms-backup.sh -h dev-host -U dba -d appdb --roles -o perms_appdb_20261113.sql
Saved permissions of appdb (24 objects, 99 statements) to perms_appdb_20261113.sql
```

Only some schemas:

```
$ ./pg-perms-backup.sh -h dev-host -U dba -d appdb -s billing,hr -o perms_billing_hr.sql
```

## What the file looks like

Header:

```sql
-- pg-perms-backup 1.0.0
-- Source:   host=dev-host port=5432 database=appdb user=dba
-- Server:   PostgreSQL 17.12
-- Taken:    2026-11-13 22:17:03 IST
-- Schemas:  all
-- Roles:    memberships included
```

Role memberships (`--roles`, PostgreSQL 16+ syntax):

```sql
-- role memberships (additive: existing memberships are not revoked)
CALL pg_temp.ppb_run('ROLE acme_auditor', 'GRANT acme_admin TO acme_auditor WITH ADMIN FALSE, INHERIT FALSE, SET TRUE');  -- granted by dba
CALL pg_temp.ppb_run('ROLE acme_clerk', 'GRANT acme_rw TO acme_clerk WITH ADMIN FALSE, INHERIT TRUE, SET TRUE');  -- granted by dba
CALL pg_temp.ppb_run('ROLE acme_report', 'GRANT acme_ro TO acme_report WITH ADMIN TRUE, INHERIT TRUE, SET TRUE');  -- granted by dba
```

Database level and settings:

```sql
-- DATABASE appdb, owner acme_owner
CALL pg_temp.ppb_object('DATABASE', 'appdb', 'acme_owner');
CALL pg_temp.ppb_run('DATABASE appdb', 'GRANT CREATE, TEMPORARY ON DATABASE appdb TO acme_admin WITH GRANT OPTION');  -- by acme_owner
CALL pg_temp.ppb_run('DATABASE appdb', 'GRANT CONNECT, CREATE, TEMPORARY ON DATABASE appdb TO acme_owner');  -- by acme_owner
CALL pg_temp.ppb_run('DATABASE appdb', 'GRANT CONNECT ON DATABASE appdb TO acme_report');  -- by acme_owner
CALL pg_temp.ppb_run('DATABASE appdb', 'GRANT CONNECT ON DATABASE appdb TO acme_ro');  -- by acme_owner

-- database and role-in-database settings (ALTER DATABASE / ALTER ROLE ... SET)
CALL pg_temp.ppb_reset_settings();
CALL pg_temp.ppb_run('DATABASE appdb settings', 'ALTER DATABASE appdb SET search_path = billing, public');
CALL pg_temp.ppb_run('DATABASE appdb settings', 'ALTER DATABASE appdb SET work_mem = ''16MB''');
CALL pg_temp.ppb_run('DATABASE appdb settings', 'ALTER ROLE acme_clerk IN DATABASE appdb SET statement_timeout = ''30s''');
CALL pg_temp.ppb_run('DATABASE appdb settings', 'ALTER ROLE acme_report IN DATABASE appdb SET "app.tenant" = ''north''');
```

No `GRANT ... TO PUBLIC` line for the database means PUBLIC's default
`CONNECT` and `TEMPORARY` had been revoked, and the replay revokes them again.

Schema level, including a grant made by a non-owner (`acme_lead` holds the
grant option), which is replayed as that role:

```sql
-- SCHEMA hr, owner acme_admin
CALL pg_temp.ppb_object('SCHEMA', 'hr', 'acme_admin');
CALL pg_temp.ppb_run('SCHEMA hr', 'GRANT CREATE, USAGE ON SCHEMA hr TO acme_admin');  -- by acme_admin
CALL pg_temp.ppb_run('SCHEMA hr', 'GRANT USAGE ON SCHEMA hr TO acme_lead WITH GRANT OPTION');  -- by acme_admin
CALL pg_temp.ppb_run('SCHEMA hr', 'GRANT USAGE ON SCHEMA hr TO acme_report', 'acme_lead');  -- by acme_lead
```

Object level with column grants and a grant chain
(owner → `acme_rw` → `acme_clerk` → `acme_lead`):

```sql
-- TABLE billing.invoices, owner acme_owner
CALL pg_temp.ppb_object('TABLE', 'billing.invoices', 'acme_owner');
CALL pg_temp.ppb_run('TABLE billing.invoices', 'GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE billing.invoices TO acme_owner');  -- by acme_owner
CALL pg_temp.ppb_run('TABLE billing.invoices', 'GRANT SELECT ON TABLE billing.invoices TO acme_ro');  -- by acme_owner
CALL pg_temp.ppb_run('TABLE billing.invoices', 'GRANT INSERT, SELECT, UPDATE ON TABLE billing.invoices TO acme_rw WITH GRANT OPTION');  -- by acme_owner
CALL pg_temp.ppb_run('TABLE billing.invoices', 'GRANT SELECT ON TABLE billing.invoices TO acme_clerk WITH GRANT OPTION', 'acme_rw');  -- by acme_rw
CALL pg_temp.ppb_run('TABLE billing.invoices', 'GRANT SELECT ON TABLE billing.invoices TO acme_lead', 'acme_clerk');  -- by acme_clerk
CALL pg_temp.ppb_run('TABLE billing.invoices', 'GRANT REFERENCES (customer) ON TABLE billing.invoices TO acme_lead WITH GRANT OPTION');  -- column grant by acme_owner
CALL pg_temp.ppb_run('TABLE billing.invoices', 'GRANT SELECT (id, customer, amount), UPDATE (amount) ON TABLE billing.invoices TO acme_report');  -- column grant by acme_owner
```

Functions, procedures and types use their full signature:

```sql
-- FUNCTION billing.total_for(text,billing.status), owner acme_owner
CALL pg_temp.ppb_object('FUNCTION', 'billing.total_for(text,billing.status)', 'acme_owner');
CALL pg_temp.ppb_run('FUNCTION billing.total_for(text,billing.status)', 'GRANT EXECUTE ON FUNCTION billing.total_for(text,billing.status) TO acme_owner');  -- by acme_owner
CALL pg_temp.ppb_run('FUNCTION billing.total_for(text,billing.status)', 'GRANT EXECUTE ON FUNCTION billing.total_for(text,billing.status) TO acme_report');  -- by acme_owner
```

Default privileges. A global rule replaces the built-in defaults, so it starts
by revoking them; a per-schema rule only adds:

```sql
-- default privileges (ALTER DEFAULT PRIVILEGES)
CALL pg_temp.ppb_reset_default_privileges(NULL, true);
CALL pg_temp.ppb_run('DEFAULT PRIVILEGES FOR ROLE acme_owner', 'ALTER DEFAULT PRIVILEGES FOR ROLE acme_owner REVOKE ALL ON FUNCTIONS FROM PUBLIC');
CALL pg_temp.ppb_run('DEFAULT PRIVILEGES FOR ROLE acme_owner', 'ALTER DEFAULT PRIVILEGES FOR ROLE acme_owner REVOKE ALL ON FUNCTIONS FROM acme_owner');
CALL pg_temp.ppb_run('DEFAULT PRIVILEGES FOR ROLE acme_owner', 'ALTER DEFAULT PRIVILEGES FOR ROLE acme_owner GRANT EXECUTE ON FUNCTIONS TO acme_owner');
CALL pg_temp.ppb_run('DEFAULT PRIVILEGES FOR ROLE acme_owner', 'ALTER DEFAULT PRIVILEGES FOR ROLE acme_owner GRANT EXECUTE ON FUNCTIONS TO acme_rw');
CALL pg_temp.ppb_run('DEFAULT PRIVILEGES FOR ROLE acme_owner IN SCHEMA billing', 'ALTER DEFAULT PRIVILEGES FOR ROLE acme_owner IN SCHEMA billing GRANT SELECT ON TABLES TO acme_ro');
```

## Replay

Everything applied:

```
$ psql -X -h dev-host -U dba -d appdb -f perms_appdb_20261113.sql

pg-perms-backup replay summary
       result       | count
--------------------+-------
 objects found      |    24
 statements applied |    98
(2 rows)

Missing objects, skipped and changed statements (empty when everything applied):
 status | object | statement | reason
--------+--------+-----------+--------
(0 rows)
```

A table that the restore didn't bring back:

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

A role that no longer exists. `acme_lead` was dropped, so its own grants are
skipped and the grant it had made to `acme_report` is made by the replaying
user instead:

```
 status          | object                 | statement                                                       | reason
-----------------+------------------------+-----------------------------------------------------------------+-----------------------------------------------------------
 skipped         | SCHEMA hr              | GRANT USAGE ON SCHEMA hr TO acme_lead WITH GRANT OPTION         | role "acme_lead" does not exist
 skipped         | TABLE hr.staff         | GRANT SELECT (id, name) ON TABLE hr.staff TO acme_lead          | role "acme_lead" does not exist
 grantor changed | SCHEMA hr              | GRANT USAGE ON SCHEMA hr TO acme_report                         | could not grant as acme_lead; granted as dba instead
```

Connected to the wrong database, nothing runs:

```
$ psql -X -d otherdb -f perms_appdb_20261113.sql
psql:perms_appdb_20261113.sql:30: ERROR:  this file was taken from database "appdb", but you are connected to "otherdb"
HINT:  Connect to the database the file was taken from (psql -d appdb).
```
