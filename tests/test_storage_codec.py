import base64
import zlib

import pandas as pd

from idx_flow_scanner.storage import decode_legacy_ohlcv_compact


def test_decode_zlib_csv_v1():
    source = pd.DataFrame({
        "Date": ["2026-08-13", "2026-08-14"],
        "Open": [450, 455],
        "High": [460, 465],
        "Low": [445, 450],
        "Close": [455, 456],
        "Volume": [1_000_000, 1_200_000],
    })
    csv_bytes = source.to_csv(index=False).encode("utf-8")
    compact = base64.b64encode(zlib.compress(csv_bytes)).decode("ascii")

    decoded = decode_legacy_ohlcv_compact(compact, "ZLIB_CSV_V1", "TPMA.JK")

    assert list(decoded["close"]) == [455, 456]
    assert list(decoded["ticker"].unique()) == ["TPMA"]
    assert decoded["date"].max().strftime("%Y-%m-%d") == "2026-08-14"


def test_unknown_codec_is_rejected_as_empty():
    assert decode_legacy_ohlcv_compact("abc", "UNKNOWN", "TPMA").empty
