from pathlib import Path


def test_warm_zapi_telemetry_only_changes_do_not_mutate_repository():
    workflow = Path(".github/workflows/warm-flow-evidence.yml").read_text(encoding="utf-8")

    assert "Publish provider telemetry" in workflow
    assert "changed = False" in workflow
    assert "if changed and meta.exists()" in workflow
    assert "telemetry-only change kept in Actions summary" in workflow
    assert "ZAPI evidence unchanged; no repository commit" in workflow
    assert "GOAPI_KEY" not in workflow
    assert "INDEX_ALPHA_KEY" not in workflow
