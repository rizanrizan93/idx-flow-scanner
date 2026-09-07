from pathlib import Path

MIGRATION = Path('supabase/migrations/20260907202500_phase4d_shadow_digest_schema_fix.sql')


def test_pgcrypto_digest_uses_extensions_schema():
    sql = MIGRATION.read_text(encoding='utf-8')
    assert "extensions.digest" in sql
    assert "public.digest" not in sql
    assert "security invoker" in sql
    assert "revoke all on function public.flow_capture_phase4d_shadow_v4(date) from public,anon,authenticated" in sql
