# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [1.0.0] - Unreleased

### Added
- `pg-perms-backup.sh`: saves the permissions of one database to a replayable
  SQL file before a restore, using only `psql`, in one read-only,
  repeatable-read transaction.
  - Database level: owner, `CONNECT`/`CREATE`/`TEMPORARY` grants,
    `ALTER DATABASE ... SET` and `ALTER ROLE ... IN DATABASE ... SET`.
  - Schema level: owners and `USAGE`/`CREATE` grants.
  - Object level: owners and grants on tables, partitioned tables, views,
    materialized views, foreign tables, sequences, functions, procedures,
    aggregates, types and domains, plus column-level grants.
  - Default privileges, global and per schema.
  - `--roles`: role memberships with `ADMIN`, and `INHERIT`/`SET` on PG16+.
  - `WITH GRANT OPTION` kept; grantor written as a comment, and non-owner
    grants replayed as their grantor, ordered along the grant chain.
  - `--schema` (comma list, repeatable), `--dry-run` (counts only),
    `-o/--output`, `-f/--force`.
  - AWS-internal users (`rdsadmin` and similar) and system schemas skipped.
- Replay file: one transaction with a database-name guard; for each object it
  sets the owner, revokes every current privilege, then grants the saved ones,
  so it converges to the saved state and can be run twice. Missing objects
  and roles are skipped and listed in a summary at the end.
- README with a full backup, restore and replay walkthrough, `EXAMPLES.md`,
  tests on PostgreSQL 14 to 17 and GitHub Actions CI.
