from pathlib import Path


MIGRATION = Path("supabase/migrations/20260907102500_phase4c_direct_slice_null_safe_targets.sql")
SQL = MIGRATION.read_text(encoding="utf-8")


def test_optional_targets_never_format_null_identifiers():
    assert "v_winner_expr:=case when v_winner is null then 'null::boolean'" in SQL
    assert "v_loser_expr:=case when v_loser is null then 'null::boolean'" in SQL
    assert "v_multi_expr:=case when v_multi is null then 'null::boolean'" in SQL
    assert "coalesce(format('c.%I',v_winner)" not in SQL
    assert "coalesce(format('c.%I',v_loser)" not in SQL
    assert "coalesce(format('c.%I',v_multi)" not in SQL


def test_optional_targets_remain_clean_label_only():
    assert "clean_hit_up_10pct_20d" in SQL
    assert "clean_hit_down_10pct_20d" in SQL
    assert "clean_hit_up_100pct_250d" in SQL
    assert "clean_close_multibagger_250d" in SQL
