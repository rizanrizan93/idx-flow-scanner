-- IDX Flow Scanner run observability
-- Safe additive migration; no scoring or evidence semantics are changed.

alter table public.flow_scan_runs
    add column if not exists attempted_count integer not null default 0 check (attempted_count >= 0),
    add column if not exists current_ticker text,
    add column if not exists heartbeat_at timestamptz,
    add column if not exists price_cache_hits integer not null default 0 check (price_cache_hits >= 0),
    add column if not exists price_fetched integer not null default 0 check (price_fetched >= 0),
    add column if not exists price_failures integer not null default 0 check (price_failures >= 0);

create index if not exists flow_scan_runs_started_status_idx
    on public.flow_scan_runs (started_at desc, status);

-- Keep the server-only access model explicit after the additive migration.
alter table public.flow_scan_runs enable row level security;
revoke all on table public.flow_scan_runs from anon, authenticated;
grant select, insert, update, delete on table public.flow_scan_runs to service_role;
