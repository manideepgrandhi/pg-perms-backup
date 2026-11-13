-- Test fixture: a destination database "appdb" with permissions at every
-- level. All names are made up. Run as a superuser on a throwaway cluster.
\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE ROLE acme_owner NOLOGIN;
CREATE ROLE acme_ro NOLOGIN;
CREATE ROLE acme_rw NOLOGIN IN ROLE acme_ro;
CREATE ROLE acme_clerk LOGIN IN ROLE acme_rw;
CREATE ROLE acme_admin NOLOGIN;
CREATE ROLE acme_auditor LOGIN NOINHERIT IN ROLE acme_admin;
CREATE ROLE acme_lead LOGIN;
CREATE ROLE acme_report LOGIN;
CREATE ROLE "Acme Mixed" NOLOGIN;
CREATE ROLE acme_gone NOLOGIN;
GRANT acme_ro TO acme_report WITH ADMIN OPTION;
GRANT pg_read_all_stats TO acme_admin;

CREATE DATABASE appdb OWNER acme_owner;
REVOKE CONNECT, TEMPORARY ON DATABASE appdb FROM PUBLIC;
GRANT CONNECT ON DATABASE appdb TO acme_ro, acme_report;
GRANT CREATE, TEMPORARY ON DATABASE appdb TO acme_admin WITH GRANT OPTION;
ALTER DATABASE appdb SET work_mem = '16MB';
ALTER DATABASE appdb SET search_path = billing, public;
ALTER ROLE acme_clerk IN DATABASE appdb SET statement_timeout = '30s';
ALTER ROLE acme_report IN DATABASE appdb SET app.tenant = 'north';

\connect appdb
SET client_min_messages = warning;
CREATE SCHEMA billing AUTHORIZATION acme_owner;
CREATE SCHEMA hr AUTHORIZATION acme_admin;
CREATE SCHEMA "Odd Schema" AUTHORIZATION acme_owner;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA billing TO acme_ro;
GRANT USAGE, CREATE ON SCHEMA billing TO acme_rw;
GRANT USAGE ON SCHEMA hr TO acme_lead WITH GRANT OPTION;
GRANT USAGE ON SCHEMA "Odd Schema" TO "Acme Mixed";

SET ROLE acme_owner;
CREATE TABLE billing.invoices (id serial PRIMARY KEY, customer text, amount numeric, card_last4 text);
CREATE TABLE billing.rates (code text PRIMARY KEY, pct numeric);
CREATE TABLE billing.events (id bigint GENERATED ALWAYS AS IDENTITY, at timestamptz, kind text) PARTITION BY RANGE (at);
CREATE TABLE billing.events_2026 PARTITION OF billing.events FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');
CREATE VIEW billing.summary AS SELECT customer, sum(amount) AS total FROM billing.invoices GROUP BY customer;
CREATE MATERIALIZED VIEW billing.daily AS SELECT 1 AS n;
CREATE SEQUENCE billing.ref_seq;
CREATE DOMAIN billing.amount AS numeric CHECK (VALUE >= 0);
CREATE TYPE billing.status AS ENUM ('open', 'paid');
CREATE TYPE billing.addr AS (street text, city text);
CREATE FUNCTION billing.total_for(p_customer text, p_status billing.status DEFAULT 'open') RETURNS numeric
  LANGUAGE sql STABLE AS $$ SELECT sum(amount) FROM billing.invoices WHERE customer = p_customer $$;
CREATE PROCEDURE billing.close_month(p_month date) LANGUAGE sql AS $$ SELECT 1 $$;
CREATE FUNCTION billing.audit_trg() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$;
CREATE TABLE "Odd Schema"."Mixed Case" ("Col A" int, "b" text);
CREATE TABLE billing.legacy (id int);

GRANT SELECT ON billing.invoices TO acme_ro;
GRANT SELECT, INSERT, UPDATE ON billing.invoices TO acme_rw WITH GRANT OPTION;
GRANT SELECT (id, customer, amount), UPDATE (amount) ON billing.invoices TO acme_report;
GRANT REFERENCES (customer) ON billing.invoices TO acme_lead WITH GRANT OPTION;
GRANT SELECT ON billing.rates TO PUBLIC;
GRANT SELECT ON billing.events TO acme_ro;
GRANT SELECT ON billing.summary TO acme_report;
GRANT SELECT ON billing.daily TO acme_ro;
GRANT USAGE, SELECT ON SEQUENCE billing.ref_seq TO acme_rw;
GRANT USAGE ON SEQUENCE billing.invoices_id_seq TO acme_rw;
REVOKE EXECUTE ON FUNCTION billing.total_for(text, billing.status) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION billing.total_for(text, billing.status) TO acme_report;
REVOKE EXECUTE ON PROCEDURE billing.close_month(date) FROM PUBLIC;
GRANT EXECUTE ON PROCEDURE billing.close_month(date) TO acme_admin;
REVOKE USAGE ON DOMAIN billing.amount FROM PUBLIC;
GRANT USAGE ON DOMAIN billing.amount TO acme_rw;
REVOKE USAGE ON TYPE billing.status FROM PUBLIC;
GRANT USAGE ON TYPE billing.status TO acme_ro;
GRANT SELECT ("Col A") ON "Odd Schema"."Mixed Case" TO "Acme Mixed";
GRANT SELECT ON billing.legacy TO acme_gone;
-- the owner gives up its own TRUNCATE on rates
REVOKE TRUNCATE ON billing.rates FROM acme_owner;
RESET ROLE;

-- a grant made by a non-owner holding the grant option
SET ROLE acme_rw;
GRANT SELECT ON billing.invoices TO acme_clerk;
RESET ROLE;
SET ROLE acme_lead;
GRANT USAGE ON SCHEMA hr TO acme_report;
RESET ROLE;

-- a foreign table (a wrapper without a handler is enough)
CREATE FOREIGN DATA WRAPPER dummy_fdw;
CREATE SERVER dummy_srv FOREIGN DATA WRAPPER dummy_fdw;
CREATE FOREIGN TABLE billing.remote_rates (code text) SERVER dummy_srv;
ALTER FOREIGN TABLE billing.remote_rates OWNER TO acme_owner;
GRANT SELECT ON billing.remote_rates TO acme_ro;

-- an object owned by someone other than the schema owner
CREATE TABLE hr.staff (id int, name text, salary numeric);
ALTER TABLE hr.staff OWNER TO acme_admin;
GRANT SELECT (id, name) ON hr.staff TO acme_lead;

-- default privileges: global and per schema
ALTER DEFAULT PRIVILEGES FOR ROLE acme_owner IN SCHEMA billing GRANT SELECT ON TABLES TO acme_ro;
ALTER DEFAULT PRIVILEGES FOR ROLE acme_owner IN SCHEMA billing GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO acme_rw;
ALTER DEFAULT PRIVILEGES FOR ROLE acme_owner IN SCHEMA billing GRANT USAGE ON SEQUENCES TO acme_rw;
ALTER DEFAULT PRIVILEGES FOR ROLE acme_owner REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE acme_owner GRANT EXECUTE ON FUNCTIONS TO acme_rw;
ALTER DEFAULT PRIVILEGES FOR ROLE acme_admin IN SCHEMA hr GRANT SELECT ON TABLES TO acme_lead WITH GRANT OPTION;
ALTER DEFAULT PRIVILEGES FOR ROLE acme_admin GRANT USAGE ON TYPES TO acme_ro;

-- a three-step grant chain (owner -> acme_rw -> acme_clerk -> acme_lead);
-- the replay file lists acme_clerk's grant before acme_rw's, so it has to retry
SET ROLE acme_rw;
GRANT SELECT ON billing.invoices TO acme_clerk WITH GRANT OPTION;
RESET ROLE;
SET ROLE acme_clerk;
GRANT SELECT ON billing.invoices TO acme_lead;
RESET ROLE;
