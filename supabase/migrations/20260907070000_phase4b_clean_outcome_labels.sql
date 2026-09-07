-- Phase 4B outcome-integrity layer.
-- Official Stock Summary prices are raw/unadjusted. A share-structure event inside
-- a forward horizon can create a mechanical price discontinuity, so factor
-- discovery must distinguish raw price-path labels from clean labels.

create or replace view public.flow_market_learning_labels_v4
with (security_invoker=true) as
with target_dates as (
  select
    s.trade_date as as_of_date,
    s.ticker,
    lead(s.trade_date,20) over w as target_date_20d,
    lead(s.trade_date,60) over w as target_date_60d,
    lead(s.trade_date,120) over w as target_date_120d,
    lead(s.trade_date,250) over w as target_date_250d
  from public.flow_official_stock_summary s
  where s.source='IDX_OFFICIAL_STOCK_SUMMARY'
    and s.source_verified
  window w as (partition by s.ticker order by s.trade_date)
), integrity as (
  select
    o.*,
    d.target_date_20d,
    d.target_date_60d,
    d.target_date_120d,
    d.target_date_250d,
    exists (
      select 1
      from public.flow_capital_action_evidence a
      where a.ticker=o.ticker
        and a.source_verified
        and a.event_type in (
          'STOCK_SPLIT','CAPITAL_REDUCTION','BONUS_SHARES','STOCK_DIVIDEND',
          'RIGHTS_ISSUE','PRIVATE_PLACEMENT','CONVERSION','WARRANT_EXERCISE','MERGER'
        )
        and a.event_date>o.as_of_date
        and d.target_date_20d is not null
        and a.event_date<=d.target_date_20d
    ) as share_structure_event_20d,
    exists (
      select 1
      from public.flow_capital_action_evidence a
      where a.ticker=o.ticker
        and a.source_verified
        and a.event_type in (
          'STOCK_SPLIT','CAPITAL_REDUCTION','BONUS_SHARES','STOCK_DIVIDEND',
          'RIGHTS_ISSUE','PRIVATE_PLACEMENT','CONVERSION','WARRANT_EXERCISE','MERGER'
        )
        and a.event_date>o.as_of_date
        and d.target_date_60d is not null
        and a.event_date<=d.target_date_60d
    ) as share_structure_event_60d,
    exists (
      select 1
      from public.flow_capital_action_evidence a
      where a.ticker=o.ticker
        and a.source_verified
        and a.event_type in (
          'STOCK_SPLIT','CAPITAL_REDUCTION','BONUS_SHARES','STOCK_DIVIDEND',
          'RIGHTS_ISSUE','PRIVATE_PLACEMENT','CONVERSION','WARRANT_EXERCISE','MERGER'
        )
        and a.event_date>o.as_of_date
        and d.target_date_120d is not null
        and a.event_date<=d.target_date_120d
    ) as share_structure_event_120d,
    exists (
      select 1
      from public.flow_capital_action_evidence a
      where a.ticker=o.ticker
        and a.source_verified
        and a.event_type in (
          'STOCK_SPLIT','CAPITAL_REDUCTION','BONUS_SHARES','STOCK_DIVIDEND',
          'RIGHTS_ISSUE','PRIVATE_PLACEMENT','CONVERSION','WARRANT_EXERCISE','MERGER'
        )
        and a.event_date>o.as_of_date
        and d.target_date_250d is not null
        and a.event_date<=d.target_date_250d
    ) as share_structure_event_250d
  from public.flow_market_learning_outcomes_v4 o
  join target_dates d
    on d.as_of_date=o.as_of_date and d.ticker=o.ticker
)
select
  i.*,
  case when i.outcome_maturity_state in ('MATURE_20D','MATURE_60D','MATURE_120D','MATURE_250D')
       and not i.share_structure_event_20d
    then i.hit_up_10pct_20d end as clean_hit_up_10pct_20d,
  case when i.outcome_maturity_state in ('MATURE_60D','MATURE_120D','MATURE_250D')
       and not i.share_structure_event_60d
    then i.hit_up_20pct_60d end as clean_hit_up_20pct_60d,
  case when i.outcome_maturity_state in ('MATURE_120D','MATURE_250D')
       and not i.share_structure_event_120d
    then i.hit_up_50pct_120d end as clean_hit_up_50pct_120d,
  case when i.outcome_maturity_state='MATURE_250D'
       and not i.share_structure_event_250d
    then i.hit_up_100pct_250d end as clean_hit_up_100pct_250d,
  case when i.outcome_maturity_state='MATURE_250D'
       and not i.share_structure_event_250d
    then i.close_multibagger_250d end as clean_close_multibagger_250d,
  case when i.outcome_maturity_state in ('MATURE_20D','MATURE_60D','MATURE_120D','MATURE_250D')
       and not i.share_structure_event_20d
    then i.hit_down_10pct_20d end as clean_hit_down_10pct_20d,
  case when i.outcome_maturity_state in ('MATURE_60D','MATURE_120D','MATURE_250D')
       and not i.share_structure_event_60d
    then i.hit_down_20pct_60d end as clean_hit_down_20pct_60d,
  case when i.outcome_maturity_state in ('MATURE_120D','MATURE_250D')
       and not i.share_structure_event_120d
    then i.hit_down_30pct_120d end as clean_hit_down_30pct_120d,
  case
    when i.share_structure_event_250d then 'UNADJUSTED_SHARE_STRUCTURE_EVENT_250D'
    when i.share_structure_event_120d then 'UNADJUSTED_SHARE_STRUCTURE_EVENT_120D'
    when i.share_structure_event_60d then 'UNADJUSTED_SHARE_STRUCTURE_EVENT_60D'
    when i.share_structure_event_20d then 'UNADJUSTED_SHARE_STRUCTURE_EVENT_20D'
    else 'CLEAN_RAW_PRICE_PATH'
  end as outcome_integrity_state,
  'MARKET_LABELS_V4_1'::text as label_version
from integrity i;

revoke all on public.flow_market_learning_labels_v4 from public,anon,authenticated;
grant select on public.flow_market_learning_labels_v4 to service_role;

comment on view public.flow_market_learning_labels_v4 is
'Phase 4B clean outcome labels. Raw outcomes remain visible, while labels that cross verified share-structure corporate actions are marked contaminated so Phase 4C does not learn mechanical unadjusted-price jumps as alpha.';
