from pathlib import Path

SQL = Path('supabase/migrations/20260908032500_evidence_expansion_point_in_time_foundation.sql').read_text()


def test_official_first_sources_are_registered():
    assert 'IDX_XBRL_FINANCIAL_REPORT' in SQL
    assert 'IDX_DISCLOSURE_ANNOUNCEMENT' in SQL
    assert 'KSEI_HOLDING_COMPOSITION' in SQL
    assert 'IDX_KSEI_MAJOR_HOLDER_FILE' in SQL
    assert 'OFFICIAL_PRIMARY' in SQL


def test_zapi_is_discovery_only_not_authority():
    assert 'ZAPI_FINANCIAL_REPORT_INDEX_ONLY' in SQL
    assert 'ZAPI_ANNOUNCEMENTS_INDEX_ONLY' in SQL
    assert 'ZAPI_OWNERSHIP_FILES_INDEX_ONLY' in SQL
    assert 'official_evidence_url_required boolean not null default true' in SQL


def test_point_in_time_fields_are_mandatory():
    assert 'published_at timestamptz not null' in SQL
    assert 'publication_time_verified boolean not null default false' in SQL
    assert 'point_in_time_eligible boolean not null default false' in SQL
    assert 'NEVER BACKDATE KNOWLEDGE TO REPORT_PERIOD_END' in SQL


def test_no_production_scoring_change():
    assert "false as production_scoring_changed" in SQL
    assert 'production_scoring_changed boolean' not in SQL


def test_private_service_role_only_contract():
    for table in (
        'flow_evidence_source_registry_v5',
        'flow_financial_filing_evidence_v5',
        'flow_financial_fact_evidence_v5',
        'flow_disclosure_evidence_v5',
        'flow_major_holder_ownership_evidence_v5',
    ):
        assert f'alter table public.{table} enable row level security' in SQL
        assert f'revoke all on public.{table} from public,anon,authenticated' in SQL
        assert f'grant select,insert,update,delete on public.{table} to service_role' in SQL


def test_no_historical_interpolation_for_ownership():
    assert 'No historical interpolation' in SQL
