-- Cover the operational-contract foreign key reported by the performance advisor.
create index if not exists flow_operational_universe_contract_v1_source_idx
  on public.flow_operational_universe_contract_v1(source_universe_contract);
