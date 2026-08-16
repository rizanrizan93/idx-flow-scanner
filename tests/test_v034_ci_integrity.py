from pathlib import Path


def test_cache_commit_does_not_embed_skip_ci_marker():
    workflow = Path('.github/workflows/warm-flow-evidence.yml').read_text(encoding='utf-8')
    assert 'git commit -m "Refresh audited flow evidence cache"' in workflow
    assert 'Refresh audited flow evidence cache [skip ci]' not in workflow
