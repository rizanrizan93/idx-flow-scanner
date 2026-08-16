from idx_flow_scanner.data import parse_yahoo_chart_payload


def test_yahoo_chart_parser_normalizes_rows():
    payload = {
        "chart": {
            "result": [{
                "timestamp": [1760000000, 1760086400],
                "indicators": {"quote": [{
                    "open": [100.0, 102.0],
                    "high": [105.0, 106.0],
                    "low": [99.0, 101.0],
                    "close": [103.0, 104.0],
                    "volume": [1000, 1200],
                }]},
            }],
            "error": None,
        }
    }
    out = parse_yahoo_chart_payload(payload, "ELSA")
    assert len(out) == 2
    assert out["ticker"].tolist() == ["ELSA", "ELSA"]
    assert out["close"].tolist() == [103.0, 104.0]
