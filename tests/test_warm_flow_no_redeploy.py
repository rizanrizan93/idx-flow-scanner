from pathlib import Path


def test_warm_flow_telemetry_only_changes_do_not_mutate_main():
    workflow = Path('.github/workflows/warm-flow-evidence.yml').read_text(encoding='utf-8')

    assert 'Publish provider telemetry without repository mutation' in workflow
    assert 'evidence_changed = False' in workflow
    assert 'if evidence_changed and new_meta.exists()' in workflow
    assert 'telemetry-only change kept in Actions summary' in workflow
    assert 'no repository commit and no Streamlit redeploy' in workflow
