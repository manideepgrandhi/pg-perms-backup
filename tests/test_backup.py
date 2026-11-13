"""Behavior tests for pg-perms-backup.sh.

Run through tests/run_tests.sh, which starts a throwaway cluster. Each test
rebuilds the fixture database "appdb" from tests/fixture.sql, takes a
permission snapshot from the catalogs (tests/state.sql), runs the backup
script, damages or replaces the database the way a restore would, replays
the file and compares the catalogs with the snapshot.
"""
import os
import re
import shutil
import subprocess
import unittest
from pathlib import Path

if os.environ.get('PPB_ISOLATED_TEST_CLUSTER') != '1':
    raise SystemExit('Run tests/run_tests.sh; it creates a disposable cluster')

ROOT = Path(os.environ['PPB_ROOT'])
WORK = Path(os.environ['PPB_WORK'])
SCRIPT = ROOT / 'pg-perms-backup.sh'
STATE_SQL = (ROOT / 'tests' / 'state.sql').read_text()
DB = 'appdb'
BINDIR = Path(os.environ['PG_BINDIR'])


def tool(name):
    p = BINDIR / name
    return str(p) if p.exists() else shutil.which(name)


def run(args, check=True, env=None):
    res = subprocess.run(args, text=True, capture_output=True,
                         env=dict(os.environ, **(env or {})), check=False)
    if check and res.returncode:
        raise AssertionError(f'{args}\nstdout:\n{res.stdout}\nstderr:\n{res.stderr}')
    return res


def sql(text, db=DB, user='postgres', check=True):
    return run(['psql', '-X', '-q', '-At', '-v', 'ON_ERROR_STOP=1', '-U', user,
                '-d', db, '-c', text], check=check)


def q1(text, db=DB):
    return sql(text, db=db).stdout.strip()


def server_num():
    return int(q1('SHOW server_version_num', db='postgres'))


def state(db=DB):
    res = subprocess.run(['psql', '-X', '-q', '-At', '-v', 'ON_ERROR_STOP=1', '-d', db],
                         input=STATE_SQL, text=True, capture_output=True, check=False)
    if res.returncode:
        raise AssertionError(res.stderr)
    return res.stdout.splitlines()


def reset_fixture(extra_sql=None):
    sql('DROP DATABASE IF EXISTS appdb WITH (FORCE)', db='postgres')
    sql('DROP DATABASE IF EXISTS proddb WITH (FORCE)', db='postgres')
    roles = q1("SELECT string_agg(quote_ident(rolname), ', ') FROM pg_roles "
               "WHERE rolname LIKE 'acme%' OR rolname LIKE 'Acme%'", db='postgres')
    if roles:
        sql(f'DROP ROLE {roles}', db='postgres')
    run(['psql', '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-d', 'postgres',
         '-f', str(ROOT / 'tests' / 'fixture.sql')])
    if server_num() >= 160000:
        # PG16+ membership options must survive as well
        sql('GRANT acme_admin TO acme_lead WITH INHERIT FALSE, SET TRUE', db='postgres')
    if extra_sql:
        sql(extra_sql)


def backup(*args, out='perms.sql', check=True, env=None):
    path = WORK / out
    if path.exists():
        path.unlink()
    res = run(['bash', str(SCRIPT), '-d', DB, '-o', str(path), *args], check=check, env=env)
    return path, res


def replay(path, db=DB, check=True):
    return run(['psql', '-X', '-d', db, '-f', str(path)], check=check)


def summary(res):
    """Map 'statements applied' -> 12 etc. from the replay summary table."""
    out = {}
    for m in re.finditer(r'^\s*(objects found|objects missing|statements [a-z ]+?)\s*\|\s*(\d+)\s*$',
                         res.stdout, re.M):
        out[m.group(1)] = int(m.group(2))
    return out


PROD_DIFFERENCES = """
REVOKE ALL ON ALL TABLES IN SCHEMA billing FROM acme_ro CASCADE;
GRANT ALL ON billing.invoices TO acme_lead;
ALTER TABLE billing.rates OWNER TO acme_admin;
GRANT USAGE, CREATE ON SCHEMA hr TO PUBLIC;
ALTER SCHEMA "Odd Schema" OWNER TO acme_admin;
REVOKE ALL ON hr.staff FROM acme_lead;
GRANT UPDATE (salary) ON hr.staff TO acme_clerk;
REVOKE USAGE ON TYPE billing.status FROM acme_ro;
GRANT USAGE ON TYPE billing.status TO PUBLIC;
GRANT EXECUTE ON FUNCTION billing.total_for(text, billing.status) TO PUBLIC;
GRANT EXECUTE ON PROCEDURE billing.close_month(date) TO acme_clerk;
REVOKE SELECT ON billing.invoices FROM acme_rw CASCADE;
ALTER DEFAULT PRIVILEGES FOR ROLE acme_admin IN SCHEMA billing GRANT ALL ON TABLES TO acme_clerk;
ALTER DEFAULT PRIVILEGES FOR ROLE acme_owner GRANT EXECUTE ON FUNCTIONS TO PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE acme_owner IN SCHEMA billing REVOKE SELECT ON TABLES FROM acme_ro;
ALTER DEFAULT PRIVILEGES FOR ROLE acme_lead GRANT SELECT ON SEQUENCES TO acme_report;
"""


def restore_from_prod(*restore_flags, prod_sql=PROD_DIFFERENCES):
    """Make a 'prod' copy of appdb with different permissions, dump it, drop
    appdb and restore the dump in its place, as a refresh from prod would."""
    sql('CREATE DATABASE proddb TEMPLATE appdb', db='postgres')
    sql(prod_sql, db='proddb')
    dump = WORK / 'prod.dump'
    run([tool('pg_dump'), '-Fc', '-d', 'proddb', '-f', str(dump)])
    sql('DROP DATABASE appdb WITH (FORCE)', db='postgres')
    sql('CREATE DATABASE appdb', db='postgres')
    res = run([tool('pg_restore'), '-d', DB, *restore_flags, str(dump)], check=False)
    # a newer pg_restore into an older server only complains about settings
    # the server lacks (e.g. transaction_timeout); anything else is a failure
    errors = [l for l in res.stderr.splitlines() if 'error:' in l and 'transaction_timeout' not in l
              and 'errors ignored on restore' not in l and 'while PROCESSING TOC' not in l
              and 'from TOC entry' not in l]
    if errors:
        raise AssertionError(res.stderr)
    sql('DROP DATABASE proddb', db='postgres')


class Base(unittest.TestCase):
    maxDiff = None

    def setUp(self):
        reset_fixture()
        self.before = state()

    def assertStateEqual(self, expected, actual):
        missing = sorted(set(expected) - set(actual))
        extra = sorted(set(actual) - set(expected))
        self.assertEqual(([], []), (missing, extra), 'lines (missing after replay, unexpected extra)')


class RestoreTests(Base):
    def test_restore_with_prod_acls_then_replay_matches_snapshot(self):
        path, _ = backup('--roles')
        restore_from_prod()
        self.assertNotEqual(self.before, state(), 'the restore should have changed permissions')
        res = replay(path)
        self.assertStateEqual(self.before, state())
        s = summary(res)
        self.assertNotIn('statements skipped', s, res.stdout)
        self.assertNotIn('objects missing', s, res.stdout)

    def test_restore_no_owner_no_acl_then_replay_matches_snapshot(self):
        path, _ = backup()
        restore_from_prod('--no-owner', '--no-acl')
        after_restore = state()
        self.assertTrue(any(l.endswith('owner=postgres') and 'billing.invoices' in l for l in after_restore))
        replay(path)
        self.assertStateEqual(self.before, state())

    def test_database_level_grants_owner_and_settings_come_back(self):
        path, _ = backup()
        restore_from_prod()
        after_restore = state()
        for line in ('DATABASE appdb owner=acme_owner', 'DATABASE appdb acme_admin=CREATE/acme_owner*',
                     'SETTING - search_path=billing, public', 'SETTING acme_report app.tenant=north',
                     'SETTING acme_clerk statement_timeout=30s'):
            self.assertIn(line, self.before)
            self.assertNotIn(line, after_restore)
        replay(path)
        now = state()
        for line in ('DATABASE appdb owner=acme_owner', 'DATABASE appdb acme_admin=CREATE/acme_owner*',
                     'SETTING - search_path=billing, public', 'SETTING acme_report app.tenant=north',
                     'SETTING acme_clerk statement_timeout=30s'):
            self.assertIn(line, now)
        self.assertNotIn('DATABASE appdb PUBLIC=CONNECT/acme_owner', now)

    def test_grant_chain_keeps_original_grantors(self):
        path, _ = backup()
        restore_from_prod('--no-acl')
        res = replay(path)
        now = state()
        self.assertIn('RELr billing.invoices acme_clerk=SELECT/acme_rw*', now)
        self.assertIn('RELr billing.invoices acme_lead=SELECT/acme_clerk', now)
        self.assertIn('SCHEMA hr acme_report=USAGE/acme_lead', now)
        self.assertNotIn('statements grantor changed', summary(res), res.stdout)

    def test_owner_without_some_own_privileges_is_restored_exactly(self):
        self.assertNotIn('RELr billing.rates acme_owner=TRUNCATE/acme_owner', self.before)
        path, _ = backup()
        restore_from_prod('--no-acl')
        replay(path)
        now = state()
        self.assertIn('RELr billing.rates acme_owner=SELECT/acme_owner', now)
        self.assertNotIn('RELr billing.rates acme_owner=TRUNCATE/acme_owner', now)

    def test_replay_twice_is_idempotent(self):
        path, _ = backup('--roles')
        restore_from_prod()
        replay(path)
        first = state()
        res = replay(path)
        self.assertEqual(first, state())
        self.assertStateEqual(self.before, first)
        s = summary(res)
        self.assertNotIn('statements skipped', s, res.stdout)
        self.assertGreater(s.get('statements applied', 0), 50)

    def test_backup_after_replay_matches_original_file(self):
        path, _ = backup('--roles')
        restore_from_prod('--no-owner')
        replay(path)
        again, _ = backup('--roles', out='perms_again.sql')
        body = lambda p: [l for l in p.read_text().splitlines() if not l.startswith('-- ')]
        self.assertEqual(body(path), body(again))

    def test_replay_on_untouched_database_changes_nothing(self):
        path, _ = backup('--roles')
        replay(path)
        self.assertEqual(self.before, state())


class SkipTests(Base):
    def test_missing_object_and_role_are_skipped_and_listed(self):
        path, _ = backup()
        restore_from_prod()
        sql('DROP TABLE billing.rates')
        sql('REVOKE ALL ON billing.legacy FROM acme_gone')
        sql('DROP ROLE acme_gone', db='postgres')
        res = replay(path)
        self.assertEqual(0, res.returncode)
        s = summary(res)
        self.assertEqual(1, s.get('objects missing'), res.stdout)
        self.assertEqual(1, s.get('statements skipped'), res.stdout)
        self.assertIn('TABLE billing.rates', res.stdout)
        self.assertRegex(res.stdout, r'skipped .*GRANT SELECT ON TABLE billing\.legacy TO acme_gone.*does not exist')
        expected = [l for l in self.before if 'billing.rates' not in l and 'acme_gone' not in l]
        self.assertStateEqual(expected, state())

    def test_missing_owner_role_keeps_current_owner(self):
        sql('CREATE ROLE acme_temp_owner', db='postgres')
        sql('ALTER TABLE billing.legacy OWNER TO acme_temp_owner')
        before = state()
        path, _ = backup()
        restore_from_prod('--no-owner', '--no-acl')
        sql('DROP ROLE acme_temp_owner', db='postgres')
        res = replay(path)
        self.assertIn('owner role acme_temp_owner not found', res.stdout)
        now = state()
        self.assertIn('RELr billing.legacy owner=postgres', now)
        self.assertIn('RELr billing.legacy postgres=SELECT/postgres', now, 'current owner kept its rights')
        expected = [l for l in before if 'billing.legacy' not in l and 'acme_temp_owner' not in l]
        self.assertStateEqual(expected, [l for l in now if 'billing.legacy' not in l])

    def test_missing_grantor_falls_back_to_owner_and_is_reported(self):
        path, _ = backup()
        restore_from_prod('--no-acl')
        sql('DROP OWNED BY acme_lead')
        sql('DROP OWNED BY acme_lead', db='postgres')
        sql('DROP ROLE acme_lead', db='postgres')
        res = replay(path)
        s = summary(res)
        self.assertEqual(1, s.get('statements grantor changed'), res.stdout)
        self.assertEqual(5, s.get('statements skipped'), res.stdout)
        self.assertRegex(res.stdout, r'grantor changed .*TO acme_report.*could not grant as acme_lead')
        now = state()
        self.assertIn('SCHEMA hr acme_report=USAGE/acme_admin', now)
        self.assertIn('RELr billing.invoices acme_clerk=SELECT/acme_rw*', now)

    def test_wrong_database_is_refused_without_changes(self):
        path, _ = backup()
        sql('CREATE DATABASE otherdb', db='postgres')
        try:
            other_before = state('otherdb')
            res = replay(path, db='otherdb', check=False)
            self.assertNotEqual(0, res.returncode)
            self.assertIn('this file was taken from database "appdb"', res.stderr)
            self.assertEqual(other_before, state('otherdb'))
        finally:
            sql('DROP DATABASE otherdb', db='postgres')

    def test_replaced_object_of_another_kind_counts_as_missing(self):
        path, _ = backup()
        sql('DROP VIEW billing.summary; CREATE TABLE billing.summary (customer text)')
        res = replay(path)
        self.assertIn('VIEW billing.summary', res.stdout)
        self.assertEqual(1, summary(res).get('objects missing'), res.stdout)


class OptionTests(Base):
    def test_schema_option_limits_the_file(self):
        path, res = backup('--schema', 'hr')
        text = path.read_text()
        self.assertIn("ppb_object('TABLE', 'hr.staff'", text)
        self.assertIn("ppb_object('SCHEMA', 'hr'", text)
        self.assertIn("ppb_object('DATABASE', 'appdb'", text)
        self.assertNotIn('billing.', text.split('-- Replay helpers')[1].split('ppb_reset_default_privileges(')[0]
                         .replace('ppb_reset_settings', ''))
        self.assertIn('ppb_reset_default_privileges(\'{hr}\'::text[], false)', text)
        self.assertIn('FOR ROLE acme_admin IN SCHEMA hr GRANT SELECT ON TABLES TO acme_lead', text)
        self.assertNotIn('ALTER DEFAULT PRIVILEGES FOR ROLE acme_admin GRANT USAGE ON TYPES', text)

    def test_schema_option_replay_only_touches_those_schemas(self):
        self.assertIn('schema(s) not found in appdb: nope', backup('-s', 'hr, nope')[1].stderr)
        path, _ = backup('-s', 'hr', '--schema', 'Odd Schema')
        restore_from_prod()
        restored = state()
        replay(path)
        now = state()

        def part(lines, pred):
            return sorted(l for l in lines if pred(l))
        in_scope = lambda l: (' hr.' in l or l.startswith('SCHEMA hr ') or 'Odd Schema' in l
                              or l.startswith('DEFACL') and ' hr ' in l)
        out_scope = lambda l: ' billing.' in l or l.startswith('SCHEMA billing ')
        self.assertEqual(part(self.before, in_scope), part(now, in_scope))
        self.assertEqual(part(restored, out_scope), part(now, out_scope))

    def test_dry_run_prints_counts_and_writes_nothing(self):
        path, res = backup('--dry-run', '--roles')
        self.assertFalse(path.exists())
        self.assertIn('nothing written (dry run)', res.stdout)
        for section in ('roles', 'database', 'schemas', 'objects', 'default privileges', 'total'):
            self.assertRegex(res.stdout, rf'(?m)^{section}\s+\d+\s+\d+$')
        m = re.search(r'(?m)^schemas\s+(\d+)', res.stdout)
        self.assertEqual(4, int(m.group(1)))   # public, billing, hr, "Odd Schema"

    def test_backup_is_read_only(self):
        path, res = backup(env={'PGOPTIONS': '-c default_transaction_read_only=on'})
        self.assertTrue(path.exists())
        self.assertEqual(self.before, state())

    def test_existing_file_needs_force(self):
        path, _ = backup()
        res = run(['bash', str(SCRIPT), '-d', DB, '-o', str(path)], check=False)
        self.assertNotEqual(0, res.returncode)
        self.assertIn('already exists', res.stderr)
        run(['bash', str(SCRIPT), '-d', DB, '-o', str(path), '--force'])

    def test_header_names_source(self):
        path, _ = backup()
        head = path.read_text().splitlines()[:8]
        self.assertTrue(any('database=appdb' in l for l in head), head)
        self.assertTrue(any(l.startswith('-- Taken:') for l in head), head)

    def test_roles_option_restores_memberships(self):
        path, _ = backup('--roles')
        sql('REVOKE acme_rw FROM acme_clerk CASCADE; REVOKE acme_ro FROM acme_report CASCADE', db='postgres')
        if server_num() >= 160000:
            sql('REVOKE acme_admin FROM acme_lead CASCADE', db='postgres')
        replay(path)
        self.assertStateEqual(self.before, state())
        if server_num() >= 160000:
            self.assertIn('MEMBER acme_lead in acme_admin admin=f inherit=false set=true', state())

    def test_without_roles_option_memberships_are_left_alone(self):
        path, _ = backup()
        self.assertNotIn('GRANT acme_rw TO acme_clerk', path.read_text())

    def test_no_internal_rds_users_or_system_schemas(self):
        sql('CREATE ROLE rdsadmin_fake_internal', db='postgres')  # name pattern ^rds without _
        try:
            sql('GRANT SELECT ON billing.rates TO rdsadmin_fake_internal')
            path, _ = backup()
            text = path.read_text()
            self.assertNotIn('rdsadmin_fake_internal', text)
            self.assertNotIn('pg_catalog.', text.split('-- Replay helpers')[1].split('$f$;\n\n')[-1])
            self.assertNotIn("'information_schema", text)
        finally:
            sql('REVOKE ALL ON billing.rates FROM rdsadmin_fake_internal')
            sql('DROP ROLE rdsadmin_fake_internal', db='postgres')

    def test_help_and_bad_option(self):
        self.assertIn('Usage:', run(['bash', str(SCRIPT), '--help']).stdout)
        res = run(['bash', str(SCRIPT), '--bogus'], check=False)
        self.assertEqual(2, res.returncode)


if __name__ == '__main__':
    unittest.main()
