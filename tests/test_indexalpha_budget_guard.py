from __future__ import annotations

from types import SimpleNamespace

from idx_flow_scanner.indexalpha_budget_guard import install_cache_only_indexalpha_finalist_loader


def test_streamlit_indexalpha_loader_is_cache_only_and_idempotent():
    calls: list[bool] = []

    def original(finalists, load_price, store, *, allow_live_pull: bool):
        calls.append(bool(allow_live_pull))
        return "frame", {"status": "LIVE_OK", "requests_attempted": 5}

    module = SimpleNamespace(_load_indexalpha_for_finalists=original)
    install_cache_only_indexalpha_finalist_loader(module)
    first_wrapper = module._load_indexalpha_for_finalists
    install_cache_only_indexalpha_finalist_loader(module)

    frame, stats = module._load_indexalpha_for_finalists(
        ["MMIX", "PKPK", "DAYA", "MDLA", "OMED"],
        lambda ticker: None,
        None,
        allow_live_pull=True,
    )

    assert module._load_indexalpha_for_finalists is first_wrapper
    assert frame == "frame"
    assert calls == [False]
    assert stats["status"] == "CACHE_ONLY_WARM_JOB_BUDGET"
    assert stats["requests_attempted"] == 0
    assert stats["streamlit_live_pull_disabled"] is True
