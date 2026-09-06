-- Operational sync for the user-confirmed IDX Flow Scanner Supabase project.
-- Target project name: Idx super scanner.
-- Target ref at execution time must be verified externally before running.
-- This file performs DML/RPC only after canonical migrations are installed.

select public.flow_sync_canonical_universe_700();
select public.flow_sync_ksei_ownership_history_2026();

-- Restore verified official IDX foreign flow, broker activity and index context
-- over the already-proven 2026-07-20..2026-09-04 production window.
do $$
declare d date;
begin
  for d in
    select gs::date
    from generate_series(date '2026-07-20', date '2026-09-04', interval '1 day') gs
    where extract(isodow from gs) between 1 and 5
  loop
    perform public.flow_refresh_official_idx_foreign(d);
    perform public.flow_refresh_official_idx_broker_activity(d);
    perform public.flow_refresh_official_idx_index(d);
  end loop;
end $$;

-- Restore factual official risk and issued-share history. These functions are
-- idempotent and fail closed on transport errors or malformed source data.
select public.flow_refresh_official_idx_risk(date '2026-01-01', date '2026-09-06');
select public.flow_refresh_official_idx_issued_history(date '2026-01-01', date '2026-09-06');

-- Refresh one complete observed shareholder/controller snapshot for all 700
-- canonical issuers in bounded chunks.
do $$
declare off integer;
begin
  for off in 0..6 loop
    perform public.flow_refresh_official_idx_shareholder_profiles(
      off * 100,
      100,
      date '2026-09-06'
    );
  end loop;
end $$;

-- Database-only evidence report. Do not make coverage claims from cache files.
select jsonb_build_object(
  'flow_issuers', jsonb_build_object(
    'active', (select count(*) from public.flow_issuers where active)
  ),
  'official_foreign', jsonb_build_object(
    'rows', (select count(*) from public.flow_vendor_foreign_flows
             where source='IDX_OFFICIAL_STOCK_SUMMARY'
               and source_verified
               and provenance_state='VERIFIED_OFFICIAL_IDX_STOCK_SUMMARY_SHARE_FLOW'),
    'tickers', (select count(distinct ticker) from public.flow_vendor_foreign_flows
                where source='IDX_OFFICIAL_STOCK_SUMMARY'
                  and source_verified
                  and provenance_state='VERIFIED_OFFICIAL_IDX_STOCK_SUMMARY_SHARE_FLOW'),
    'sessions', (select count(distinct trade_date) from public.flow_vendor_foreign_flows
                 where source='IDX_OFFICIAL_STOCK_SUMMARY'
                   and source_verified
                   and provenance_state='VERIFIED_OFFICIAL_IDX_STOCK_SUMMARY_SHARE_FLOW'),
    'latest', (select max(trade_date) from public.flow_vendor_foreign_flows
               where source='IDX_OFFICIAL_STOCK_SUMMARY'
                 and source_verified
                 and provenance_state='VERIFIED_OFFICIAL_IDX_STOCK_SUMMARY_SHARE_FLOW')
  ),
  'ksei_ownership', jsonb_build_object(
    'rows', (select count(*) from public.flow_ownership_evidence
             where provenance_state='VERIFIED_KSEI_REGISTRATION_COMPOSITION'
               and source_verified),
    'tickers', (select count(distinct ticker) from public.flow_ownership_evidence
                where provenance_state='VERIFIED_KSEI_REGISTRATION_COMPOSITION'
                  and source_verified),
    'report_dates', (select count(distinct report_date) from public.flow_ownership_evidence
                     where provenance_state='VERIFIED_KSEI_REGISTRATION_COMPOSITION'
                       and source_verified),
    'latest', (select max(report_date) from public.flow_ownership_evidence
               where provenance_state='VERIFIED_KSEI_REGISTRATION_COMPOSITION'
                 and source_verified)
  ),
  'official_broker_activity', jsonb_build_object(
    'rows', (select count(*) from public.flow_official_broker_activity
             where source_verified),
    'sessions', (select count(distinct trade_date) from public.flow_official_broker_activity
                 where source_verified),
    'brokers', (select count(distinct broker_code) from public.flow_official_broker_activity
                where source_verified)
  ),
  'official_risk', jsonb_build_object(
    'rows', (select count(*) from public.flow_official_risk_events where source_verified),
    'tickers', (select count(distinct ticker) from public.flow_official_risk_events where source_verified)
  ),
  'capital_actions', jsonb_build_object(
    'rows', (select count(*) from public.flow_capital_action_evidence
             where source_verified
               and provenance_state='VERIFIED_IDX_CAPITAL_ACTION_EVIDENCE'),
    'tickers', (select count(distinct ticker) from public.flow_capital_action_evidence
                where source_verified
                  and provenance_state='VERIFIED_IDX_CAPITAL_ACTION_EVIDENCE')
  ),
  'official_index', jsonb_build_object(
    'rows', (select count(*) from public.flow_official_index_summary where source_verified),
    'sessions', (select count(distinct trade_date) from public.flow_official_index_summary where source_verified),
    'indices', (select count(distinct index_code) from public.flow_official_index_summary where source_verified)
  ),
  'official_shareholders', jsonb_build_object(
    'rows', (select count(*) from public.flow_official_shareholder_profiles where source_verified),
    'tickers', (select count(distinct ticker) from public.flow_official_shareholder_profiles where source_verified),
    'controller_tickers', (select count(distinct ticker) from public.flow_official_shareholder_profiles
                           where source_verified and is_controller)
  )
) as idx_flow_stage1_3_sync_report;
