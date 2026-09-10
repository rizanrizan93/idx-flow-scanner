-- Supabase advisor verified these are byte-for-byte equivalent btree key
-- definitions.  Retain the original canonical indexes and remove only the
-- later duplicate names.
drop index if exists public.flow_risk_events_ticker_date_v4_idx;
drop index if exists public.flow_shareholders_ticker_observed_v4_idx;
