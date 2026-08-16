alter table public.flow_vendor_foreign_flows
  add column if not exists volume numeric not null default 0,
  add column if not exists traded_value numeric not null default 0;

comment on column public.flow_vendor_foreign_flows.volume is
  'Daily traded share volume used to keep foreign-flow intensity dimensionally consistent.';
comment on column public.flow_vendor_foreign_flows.traded_value is
  'Daily traded value retained for audit/context; foreign buy/sell fields remain in flow_unit units.';
