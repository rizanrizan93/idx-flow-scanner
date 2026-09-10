-- Preserve historical storage measurements when a physical storage object is renamed.
-- The relation-measurement rows track the lineage of the physical object, so an
-- object_name rename must cascade instead of blocking the storage compaction migration.

alter table public.flow_storage_relation_measurement_v1
  drop constraint if exists flow_storage_relation_measurement_v1_object_name_fkey;

alter table public.flow_storage_relation_measurement_v1
  add constraint flow_storage_relation_measurement_v1_object_name_fkey
  foreign key (object_name)
  references public.flow_storage_object_registry_v1(object_name)
  on update cascade;
