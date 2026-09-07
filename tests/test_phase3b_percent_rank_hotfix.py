from pathlib import Path


HOTFIX = Path(
    "supabase/migrations/20260907044500_phase3b_percent_rank_numeric_cast.sql"
)


def test_phase3b_percent_rank_is_cast_before_two_arg_round():
    sql = HOTFIX.read_text(encoding="utf-8")
    assert "percent_rank() over(order by broker_consensus_proxy_score)" in sql
    assert "(percent_rank() over(order by broker_consensus_proxy_score))::numeric" in sql
    assert "round((100::numeric*" in sql
    assert "),2) rank_pct" in sql


def test_phase3b_hotfix_changes_no_proxy_weights_or_semantics():
    sql = HOTFIX.read_text(encoding="utf-8")
    assert "0.30*" in sql
    assert "+0.25*" in sql
    assert "+0.20*" in sql
    assert "+0.15*" in sql
    assert "+0.10*" in sql
    assert "CO_ACTIVITY_AFFINITY_NOT_BUY_SELL" in sql
    assert "final_score" not in sql
    assert "production_authorized" not in sql
