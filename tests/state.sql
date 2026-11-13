-- Prints the permission state of the current database (plus role memberships
-- and the database's settings), one sorted line per fact, by name, so two
-- databases or two points in time can be compared.
SET search_path = pg_catalog;
WITH rn AS (SELECT oid, rolname FROM pg_roles UNION ALL SELECT 0, 'PUBLIC'),
nsp AS (
  SELECT oid, nspname, nspowner, nspacl FROM pg_namespace
  WHERE nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast') AND nspname !~ '^pg_(toast_)?temp_'
),
objs AS (
  SELECT 'DATABASE' AS kind, datname::text AS ident, datdba AS owner,
         coalesce(datacl, acldefault('d', datdba)) AS acl
  FROM pg_database WHERE datname = current_database()
  UNION ALL
  SELECT 'SCHEMA', nspname, nspowner, coalesce(nspacl, acldefault('n', nspowner)) FROM nsp
  UNION ALL
  SELECT 'REL' || c.relkind::text, format('%I.%I', n.nspname, c.relname), c.relowner,
         coalesce(c.relacl, acldefault(CASE c.relkind WHEN 'S' THEN 's'::"char" ELSE 'r'::"char" END, c.relowner))
  FROM pg_class c JOIN nsp n ON n.oid = c.relnamespace WHERE c.relkind IN ('r','p','v','m','f','S')
  UNION ALL
  SELECT 'PROC', p.oid::regprocedure::text, p.proowner, coalesce(p.proacl, acldefault('f', p.proowner))
  FROM pg_proc p JOIN nsp n ON n.oid = p.pronamespace
  UNION ALL
  SELECT 'TYPE', format_type(t.oid, NULL), t.typowner, coalesce(t.typacl, acldefault('T', t.typowner))
  FROM pg_type t JOIN nsp n ON n.oid = t.typnamespace
  WHERE t.typtype IN ('b','c','d','e','r') AND (t.typrelid = 0 OR (SELECT relkind FROM pg_class WHERE oid = t.typrelid) = 'c')
    AND NOT EXISTS (SELECT 1 FROM pg_type e WHERE e.typarray = t.oid)
)
SELECT line FROM (
  SELECT format('%s %s owner=%s', o.kind, o.ident, ro.rolname) AS line
  FROM objs o JOIN rn ro ON ro.oid = o.owner
  UNION ALL
  SELECT format('%s %s %s=%s/%s%s', o.kind, o.ident, rg.rolname, a.privilege_type, rr.rolname,
                CASE WHEN a.is_grantable THEN '*' ELSE '' END)
  FROM objs o CROSS JOIN LATERAL aclexplode(o.acl) a
  JOIN rn rg ON rg.oid = a.grantee JOIN rn rr ON rr.oid = a.grantor
  UNION ALL
  SELECT format('COLUMN %I.%I.%I %s=%s/%s%s', n.nspname, c.relname, att.attname, rg.rolname,
                a.privilege_type, rr.rolname, CASE WHEN a.is_grantable THEN '*' ELSE '' END)
  FROM pg_attribute att JOIN pg_class c ON c.oid = att.attrelid JOIN nsp n ON n.oid = c.relnamespace
  CROSS JOIN LATERAL aclexplode(att.attacl) a
  JOIN rn rg ON rg.oid = a.grantee JOIN rn rr ON rr.oid = a.grantor
  WHERE att.attacl IS NOT NULL AND att.attnum > 0
  UNION ALL
  SELECT format('DEFACL %s %s %s %s=%s/%s%s', r.rolname, coalesce(n.nspname, '-'), d.defaclobjtype,
                rg.rolname, a.privilege_type, rr.rolname, CASE WHEN a.is_grantable THEN '*' ELSE '' END)
  FROM pg_default_acl d JOIN rn r ON r.oid = d.defaclrole LEFT JOIN pg_namespace n ON n.oid = d.defaclnamespace
  CROSS JOIN LATERAL aclexplode(d.defaclacl) a
  JOIN rn rg ON rg.oid = a.grantee JOIN rn rr ON rr.oid = a.grantor
  UNION ALL
  SELECT format('SETTING %s %s', coalesce(r.rolname, '-'), cfg)
  FROM pg_db_role_setting s JOIN pg_database d ON d.oid = s.setdatabase AND d.datname = current_database()
  LEFT JOIN pg_roles r ON r.oid = s.setrole CROSS JOIN LATERAL unnest(s.setconfig) cfg
  UNION ALL
  SELECT DISTINCT format('MEMBER %s in %s admin=%s inherit=%s set=%s', m.rolname, r.rolname,
                am.admin_option, to_jsonb(am) ->> 'inherit_option', to_jsonb(am) ->> 'set_option')
  FROM pg_auth_members am JOIN pg_roles r ON r.oid = am.roleid JOIN pg_roles m ON m.oid = am.member
  WHERE m.rolname !~ '^pg_'
) s
ORDER BY line COLLATE "C";
