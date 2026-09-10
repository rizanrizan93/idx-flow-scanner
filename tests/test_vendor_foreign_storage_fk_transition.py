from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PREP = ROOT / "supabase/migrations/20260910042528_storage_registry_object_name_update_cascade_v1.sql"
COMPACTION = ROOT / "supabase/migrations/20260910042612_vendor_foreign_canonical_view_v1.sql"


def _sql(path: Path) -> str:
    return path.read_text(encoding="utf-8").lower()


def test_relation_measurement_fk_cascades_object_name_rename() -> None:
    sql = _sql(PREP)
    assert "flow_storage_relation_measurement_v1_object_name_fkey" in sql
    assert "references public.flow_storage_object_registry_v1(object_name)" in sql
    assert "on update cascade" in sql


def test_fk_transition_precedes_vendor_compaction() -> None:
    assert PREP.name < COMPACTION.name
    compaction = _sql(COMPACTION)
    assert "update public.flow_storage_object_registry_v1 set" in compaction
    assert "object_name='flow_vendor_foreign_transport_v1'" in compaction


def test_storage_history_is_not_deleted_to_make_rename_work() -> None:
    sql = _sql(PREP)
    assert "delete from public.flow_storage_relation_measurement_v1" not in sql
    assert "truncate" not in sql
