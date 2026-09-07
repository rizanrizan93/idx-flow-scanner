from pathlib import Path


SQL = Path(
    "supabase/migrations/20260907070000_phase4b_clean_outcome_labels.sql"
).read_text(encoding="utf-8")


def test_clean_labels_keep_raw_outcomes_and_mark_share_structure_contamination():
    assert "flow_market_learning_outcomes_v4" in SQL
    assert "flow_market_learning_labels_v4" in SQL
    for event in (
        "STOCK_SPLIT",
        "CAPITAL_REDUCTION",
        "BONUS_SHARES",
        "STOCK_DIVIDEND",
        "RIGHTS_ISSUE",
        "PRIVATE_PLACEMENT",
        "CONVERSION",
        "WARRANT_EXERCISE",
        "MERGER",
    ):
        assert event in SQL
    assert "share_structure_event_250d" in SQL
    assert "UNADJUSTED_SHARE_STRUCTURE_EVENT_250D" in SQL
    assert "CLEAN_RAW_PRICE_PATH" in SQL


def test_clean_winner_loser_and_multibagger_labels_are_fail_closed():
    required = (
        "clean_hit_up_10pct_20d",
        "clean_hit_up_20pct_60d",
        "clean_hit_up_50pct_120d",
        "clean_hit_up_100pct_250d",
        "clean_close_multibagger_250d",
        "clean_hit_down_10pct_20d",
        "clean_hit_down_20pct_60d",
        "clean_hit_down_30pct_120d",
    )
    for name in required:
        assert name in SQL
    assert "not i.share_structure_event_250d" in SQL
    assert "MARKET_LABELS_V4_1" in SQL


def test_phase4c_warning_is_explicit():
    assert "does not learn mechanical unadjusted-price jumps as alpha" in SQL
