from __future__ import annotations

from types import SimpleNamespace

import pandas as pd

from idx_flow_scanner.ui_contract_guard import UI_CONTRACT_REVISION, install_truthful_output_lanes


class FakeStreamlit:
    def __init__(self) -> None:
        self.calls: list[tuple[str, object, dict]] = []

    def checkbox(self, label, *args, **kwargs):
        self.calls.append(("checkbox", label, dict(kwargs)))
        return kwargs.get("value", True)

    def subheader(self, label, *args, **kwargs):
        self.calls.append(("subheader", label, dict(kwargs)))

    def caption(self, body, *args, **kwargs):
        self.calls.append(("caption", body, dict(kwargs)))

    def info(self, body, *args, **kwargs):
        self.calls.append(("info", body, dict(kwargs)))

    def dataframe(self, data=None, *args, **kwargs):
        self.calls.append(("dataframe", data.copy() if isinstance(data, pd.DataFrame) else data, dict(kwargs)))
        return data


def _app():
    return SimpleNamespace(st=FakeStreamlit())


def test_indexalpha_control_is_truthful_cache_only_and_disabled():
    app = _app()
    install_truthful_output_lanes(app)

    value = app.st.checkbox(
        "Index Alpha live pull untuk Final Top 5",
        value=True,
        help="legacy live-pull help",
    )

    assert value is False
    kind, label, kwargs = app.st.calls[-1]
    assert kind == "checkbox"
    assert label == "Index Alpha broker evidence (cache-only)"
    assert kwargs["disabled"] is True
    assert kwargs["value"] is False
    assert "GitHub Warm Flow Evidence" in kwargs["help"]
    assert app._idxflow_ui_contract_revision == UI_CONTRACT_REVISION


def test_guarded_lane_removes_stale_score_floor_claim():
    app = _app()
    install_truthful_output_lanes(app)

    app.st.subheader("2. Final Guarded Top 5")
    app.st.caption(
        "Cohort ini dipilih sebelum Index Alpha. Foreign coverage minimum 70%, score ≥65, "
        "distribution <70, dan price-quality/staleness gate harus lolos."
    )

    captions = [body for kind, body, _ in app.st.calls if kind == "caption"]
    subheaders = [body for kind, body, _ in app.st.calls if kind == "subheader"]
    assert subheaders[-1] == "2. Guarded Accumulation Watch — Top 5"
    assert "score ≥65" not in captions[-1]
    assert "Tidak ada hard absolute-score floor" in captions[-1]


def test_broker_verified_production_filters_pending_and_noneligible_rows():
    app = _app()
    install_truthful_output_lanes(app)

    app.st.subheader("3. Broker-Verified Top 5")
    frame = pd.DataFrame(
        [
            {
                "ticker": "MMIX",
                "broker_verification_status": "BROKER_PENDING",
                "evidence_tier": "PRICE_PROXY",
                "real_money_state": "GUARDED",
            },
            {
                "ticker": "GOOD",
                "broker_verification_status": "BROKER_VERIFIED",
                "evidence_tier": "BROKER_DIRECT",
                "real_money_state": "ELIGIBLE",
            },
            {
                "ticker": "NOTELIG",
                "broker_verification_status": "BROKER_VERIFIED",
                "evidence_tier": "BROKER_DIRECT",
                "real_money_state": "GUARDED",
            },
        ]
    )
    app.st.dataframe(frame)

    subheaders = [body for kind, body, _ in app.st.calls if kind == "subheader"]
    shown = [body for kind, body, _ in app.st.calls if kind == "dataframe"]
    assert subheaders[-1] == "3. Broker-Verified Production"
    assert shown[-1]["ticker"].tolist() == ["GOOD"]


def test_empty_production_lane_reports_no_verified_candidate():
    app = _app()
    install_truthful_output_lanes(app)
    app.st.subheader("3. Broker-Verified Top 5")
    app.st.dataframe(
        pd.DataFrame(
            [{
                "ticker": "MMIX",
                "broker_verification_status": "BROKER_PENDING",
                "evidence_tier": "PRICE_PROXY",
                "real_money_state": "GUARDED",
            }]
        )
    )

    assert not [body for kind, body, _ in app.st.calls if kind == "dataframe"]
    messages = [body for kind, body, _ in app.st.calls if kind == "info"]
    assert messages
    assert "Belum ada Broker-Verified Production" in messages[-1]
