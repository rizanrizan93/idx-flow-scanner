-- IDX Flow Scanner maintenance script
-- Target ONLY: Supabase project "Idx emir framework" (legacy / first Emir project)
-- Project ref: utgrknbmtmhpjurvcabg
-- DO NOT run against "Idx emir framework v2".
--
-- Purpose:
--   Remove legacy application tables from the public schema while preserving
--   Supabase/system schemas and extension-owned objects. After this succeeds,
--   apply ../migrations/001_initial_schema.sql.
--
-- This is intentionally kept under maintenance/ rather than migrations/ so it
-- cannot be mistaken for a normal application migration.

DO $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT n.nspname AS schema_name, c.relname AS relation_name
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relkind IN ('r', 'p')
          AND NOT EXISTS (
              SELECT 1
              FROM pg_depend d
              JOIN pg_extension e ON e.oid = d.refobjid
              WHERE d.objid = c.oid
                AND d.deptype = 'e'
          )
    LOOP
        EXECUTE format('DROP TABLE IF EXISTS %I.%I CASCADE', r.schema_name, r.relation_name);
    END LOOP;
END
$$;

-- Safety verification: after cleanup this should return only extension-owned
-- public tables (if any). Flow tables are created by 001_initial_schema.sql.
SELECT c.relname AS remaining_public_table
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relkind IN ('r', 'p')
ORDER BY c.relname;
