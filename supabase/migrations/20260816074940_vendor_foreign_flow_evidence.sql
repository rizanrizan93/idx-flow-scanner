create table if not exists public.flow_vendor_foreign_flows (
  ticker text not null,
  trade_date date not null,
  foreign_buy numeric not null default 0,
  foreign_sell numeric not null default 0,
  foreign_net numeric not null default 0,
  flow_unit text not null default 'IDR' check (flow_unit in ('IDR','SHARES')),
  market_type text not null default 'ALL',
  source text not null,
  source_verified boolean not null default false,
  source_url text,
  provenance_state text,
  retrieved_at timestamptz not null default now(),
  primary key (ticker, trade_date, source, market_type)
);

create index if not exists flow_vendor_foreign_flows_ticker_date_idx
  on public.flow_vendor_foreign_flows (ticker, trade_date desc);

alter table public.flow_vendor_foreign_flows enable row level security;
revoke all on table public.flow_vendor_foreign_flows from anon, authenticated;
grant select, insert, update, delete on table public.flow_vendor_foreign_flows to service_role;

comment on table public.flow_vendor_foreign_flows is
  'Verified non-IDX foreign-flow evidence kept separate from official IDX share-count evidence to preserve units and provenance.';
