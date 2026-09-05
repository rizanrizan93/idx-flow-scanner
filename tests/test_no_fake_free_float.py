from pathlib import Path


def test_canonical_runtime_never_computes_free_float_from_tradable_shares() -> None:
    source = Path("src/idx_flow_scanner/canonical_slow_evidence.py").read_text(encoding="utf-8")
    assert '"free_float_pct": None' in source
    assert 'UNAVAILABLE_NOT_INFERRED_FROM_TRADABLE_SHARES' in source
