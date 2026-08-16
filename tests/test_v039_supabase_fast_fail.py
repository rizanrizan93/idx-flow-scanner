import supabase

from idx_flow_scanner.storage import SupabaseStore


def test_supabase_store_sets_bounded_postgrest_timeout(monkeypatch):
    captured = {}

    def fake_create_client(url, key, options=None):
        captured["url"] = url
        captured["key"] = key
        captured["options"] = options
        return object()

    monkeypatch.setattr(supabase, "create_client", fake_create_client)
    monkeypatch.setenv("FLOW_SUPABASE_POSTGREST_TIMEOUT_SECONDS", "10")

    store = SupabaseStore("https://example.supabase.co", "sb_secret_test")

    assert store.postgrest_timeout_seconds == 10.0
    assert captured["options"].postgrest_client_timeout == 10.0
    assert captured["options"].storage_client_timeout == 10.0


def test_supabase_timeout_is_clamped(monkeypatch):
    captured = {}
    monkeypatch.setattr(
        supabase,
        "create_client",
        lambda url, key, options=None: captured.setdefault("options", options) or object(),
    )
    monkeypatch.setenv("FLOW_SUPABASE_POSTGREST_TIMEOUT_SECONDS", "999")

    store = SupabaseStore("https://example.supabase.co", "sb_secret_test")

    assert store.postgrest_timeout_seconds == 30.0
