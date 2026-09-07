from pathlib import Path


MIGRATION = Path(
    "supabase/migrations/20260907011500_phase1b_broker_directory_quality.sql"
)


def _sql() -> str:
    return MIGRATION.read_text(encoding="utf-8")


def test_phase1b_uses_direct_official_exchange_member_directory():
    sql = _sql()
    assert "https://block.idx.id/primary/ExchangeMember/GetBroker?length=200&start=0" in sql
    assert "recordsTotal" in sql
    assert "api_rows <> records_total" in sql
    assert "api_rows < 80 or api_rows > 100" in sql
    assert "missing name/status/license" in sql


def test_phase1b_directory_is_private_flow_namespace_with_provenance():
    sql = _sql()
    assert "flow_official_broker_directory" in sql
    assert "IDX_OFFICIAL_EXCHANGE_MEMBER_DIRECTORY" in sql
    assert "VERIFIED_OFFICIAL_IDX_EXCHANGE_MEMBER_DIRECTORY" in sql
    assert "enable row level security" in sql
    assert "from public, anon, authenticated" in sql
    assert "to service_role" in sql
    assert "profil-anggota-bursa/" in sql


def test_phase1b_preserves_historical_identity_instead_of_rewriting_names():
    sql = _sql()
    assert "flow_broker_identity_history" in sql
    assert "valid_from" in sql
    assert "valid_to" in sql
    assert "identity_segment" in sql
    assert "HISTORICAL_ONLY" in sql
    assert "NAME_VARIANT_OR_RENAME" in sql
    assert "does not rewrite old names" in sql


def test_phase1b_training_quality_is_fail_closed_and_not_fixed_to_88():
    sql = _sql()
    assert "flow_broker_session_quality" in sql
    assert "training_quality_state" in sql
    assert "UNVERIFIED_SOURCE" in sql
    assert "NON_OFFICIAL_SOURCE_URL" in sql
    assert "NEGATIVE_ACTIVITY_METRIC" in sql
    assert "DUPLICATE_BROKER_CODE" in sql
    assert "broker_count < 80" in sql
    assert "broker_count > 100" in sql
    assert "broker_count < 85 or s.broker_count > 95" in sql
    assert "forced to equal today's 88" not in sql.lower()


def test_phase1b_requires_at_least_250_clean_sessions_before_ready():
    sql = _sql()
    assert "flow_phase1b_broker_quality_summary" in sql
    assert "q.pass_sessions >= 250" in sql
    assert "q.fail_sessions=0" in sql
    assert "PHASE1B_READY" in sql
    assert "PHASE1B_NOT_READY" in sql


def test_phase1b_directory_refresh_is_scheduled_but_scoring_is_untouched():
    sql = _sql()
    assert "flow-official-idx-broker-directory-daily" in sql
    assert "35 10 * * *" in sql
    assert "final_score" not in sql
    assert "BROKER_BEHAVIOR_OVERLAY_WEIGHT" not in sql
    assert "execution_ready" not in sql
