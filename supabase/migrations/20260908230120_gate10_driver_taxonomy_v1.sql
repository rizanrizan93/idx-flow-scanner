-- Gate 10: frozen predictive-driver taxonomy and attribution contract.
-- Research/calibration only. This migration has no production scoring call path.

create table if not exists public.flow_driver_state_catalog_v1 (
  state text primary key,
  semantics text not null
);

insert into public.flow_driver_state_catalog_v1(state,semantics) values
('AVAILABLE','Evidence is PIT-available, valid, applicable and sufficiently seasoned.'),
('MISSING','Expected evidence is absent; never imputed to a neutral score.'),
('STALE','Evidence exists but exceeds the frozen staleness boundary.'),
('INVALID','Evidence failed source, value, revision, or PIT validation.'),
('NOT_APPLICABLE','Driver is not economically applicable to this observation.'),
('INSUFFICIENT_HISTORY','The frozen minimum-history rule is not met.')
on conflict(state) do nothing;

create table if not exists public.flow_driver_registry_v1 (
  registry_version text not null,
  driver_id text not null,
  family text not null,
  description text not null,
  raw_source text not null,
  source_table text not null,
  source_fields jsonb not null,
  mathematical_definition text not null,
  direction_hypothesis smallint not null check(direction_hypothesis in (-1,0,1)),
  threshold_definition text not null,
  update_frequency text not null,
  source_timestamp text not null,
  effective_availability_rule text not null,
  pit_safe boolean not null,
  revision_safe boolean not null,
  historical_availability text not null,
  minimum_history_sessions integer not null check(minimum_history_sessions>=0),
  sector_applicability text not null,
  liquidity_applicability text not null,
  missing_data_semantics text not null,
  stale_definition text not null,
  invalid_definition text not null,
  not_applicable_rule text not null,
  horizon_candidates integer[] not null,
  expected_relationship text not null,
  promotion_eligibility text not null,
  interaction_eligibility boolean not null,
  evaluation_eligible boolean not null,
  frozen_at timestamptz not null,
  production_influence_enabled boolean not null default false check(production_influence_enabled=false),
  primary key(registry_version,driver_id),
  constraint flow_driver_registry_v1_family_ck check(family in (
    'FLOW_PARTICIPANT','PRICE_VOLUME','MARKET_SECTOR','TECHNICAL_STRUCTURE',
    'FINANCIAL','OWNERSHIP_FREE_FLOAT','CORPORATE_EVENT','LIQUIDITY_TRADABILITY'
  )),
  constraint flow_driver_registry_v1_horizon_ck check(horizon_candidates <@ array[5,20,60]::integer[])
);

with d as (
  select * from jsonb_to_recordset($drivers$
  [
    {"id":"FLOW_FOREIGN_ACCUMULATION","family":"FLOW_PARTICIPANT","description":"Sustained verified foreign net buying relative to volume.","table":"flow_market_learning_panel_v4","fields":["foreign_net_volume_pct"],"formula":"foreign_net_volume_pct","direction":1,"threshold":"XSEC_PERCENT_RANK_BOTTOM_20_TOP_80","history":20,"eligible":true,"interact":true,"expected":"Higher values predict positive forward alpha."},
    {"id":"FLOW_FOREIGN_DISTRIBUTION","family":"FLOW_PARTICIPANT","description":"Sustained verified foreign net selling relative to volume.","table":"flow_market_learning_panel_v4","fields":["foreign_net_volume_pct"],"formula":"-foreign_net_volume_pct","direction":1,"threshold":"XSEC_PERCENT_RANK_BOTTOM_20_TOP_80","history":20,"eligible":true,"interact":false,"expected":"Higher transformed values predict negative raw alpha and are evaluated after sign orientation."},
    {"id":"FLOW_PARTICIPANT_ACCUMULATION","family":"FLOW_PARTICIPANT","description":"Positive signed abnormal stock activity, without claiming broker buy/sell identity.","table":"flow_market_learning_panel_v4","fields":["stock_residual_activity_z","return_5d_pct"],"formula":"stock_residual_activity_z when return_5d_pct>0 else 0","direction":1,"threshold":"XSEC_PERCENT_RANK_BOTTOM_20_TOP_80","history":20,"eligible":true,"interact":false,"expected":"Positive abnormal activity predicts positive forward alpha."},
    {"id":"FLOW_PARTICIPANT_DISTRIBUTION","family":"FLOW_PARTICIPANT","description":"Negative signed abnormal stock activity, without claiming broker buy/sell identity.","table":"flow_market_learning_panel_v4","fields":["stock_residual_activity_z","return_5d_pct"],"formula":"stock_residual_activity_z when return_5d_pct<0 else 0","direction":-1,"threshold":"XSEC_PERCENT_RANK_BOTTOM_20_TOP_80","history":20,"eligible":true,"interact":false,"expected":"Higher distribution intensity predicts lower forward alpha."},
    {"id":"FLOW_PERSISTENCE_20D","family":"FLOW_PARTICIPANT","description":"Fraction of the trailing 20 sessions with positive verified foreign net flow.","table":"flow_official_stock_summary","fields":["trade_date","foreign_buy","foreign_sell"],"formula":"avg((foreign_buy-foreign_sell)>0) over trailing 20 sessions","direction":1,"threshold":"RAW_BOTTOM_0_35_TOP_0_65","history":20,"eligible":true,"interact":false,"expected":"Persistent accumulation predicts positive forward alpha."},
    {"id":"FLOW_ACCELERATION_5V20","family":"FLOW_PARTICIPANT","description":"Short-window foreign flow intensity minus its 20-session mean.","table":"flow_market_learning_panel_v4","fields":["foreign_net_volume_pct","as_of_date"],"formula":"avg5(foreign_net_volume_pct)-avg20(foreign_net_volume_pct)","direction":1,"threshold":"XSEC_PERCENT_RANK_BOTTOM_20_TOP_80","history":20,"eligible":true,"interact":false,"expected":"Positive acceleration predicts positive forward alpha."},
    {"id":"FLOW_CONCENTRATION_CHANGE_20D","family":"FLOW_PARTICIPANT","description":"Change in ticker-level participant concentration.","table":"UNAVAILABLE_TICKER_PARTICIPANT_HISTORY","fields":[],"formula":"not computable from market-wide broker summaries","direction":0,"threshold":"NOT_FROZEN_NO_VALID_SOURCE","history":40,"eligible":false,"interact":false,"pit":false,"revision":false,"availability":"INSUFFICIENT_EVIDENCE","expected":"No directional claim until ticker-level participant history exists."},
    {"id":"FLOW_ABSORPTION","family":"FLOW_PARTICIPANT","description":"Positive flow during muted price response and abnormal activity.","table":"flow_market_learning_panel_v4","fields":["foreign_net_volume_pct","return_5d_pct","stock_residual_activity_z"],"formula":"foreign_net_volume_pct-abs(return_5d_pct)+greatest(stock_residual_activity_z,0)","direction":1,"threshold":"XSEC_PERCENT_RANK_BOTTOM_20_TOP_80","history":20,"eligible":true,"interact":false,"expected":"Stronger absorption predicts positive forward alpha."},
    {"id":"FLOW_DISTRIBUTION_RISK","family":"FLOW_PARTICIPANT","description":"Negative flow combined with abnormal activity and weak price.","table":"flow_market_learning_panel_v4","fields":["foreign_net_volume_pct","return_5d_pct","stock_residual_activity_z"],"formula":"greatest(-foreign_net_volume_pct,0)+greatest(-return_5d_pct,0)+greatest(stock_residual_activity_z,0)","direction":-1,"threshold":"XSEC_PERCENT_RANK_BOTTOM_20_TOP_80","history":20,"eligible":true,"interact":false,"expected":"Higher distribution risk predicts lower forward alpha."},

    {"id":"PV_VOLUME_EXPANSION","family":"PRICE_VOLUME","description":"Current volume relative to its trailing 20-session mean.","table":"flow_market_learning_panel_v4","fields":["volume","as_of_date"],"formula":"volume/nullif(avg20(volume),0)","direction":1,"threshold":"RAW_BOTTOM_0_80_TOP_1_50","history":20,"eligible":true,"interact":true,"expected":"Volume expansion supporting price direction predicts stronger continuation."},
    {"id":"PV_ABNORMAL_VOLUME","family":"PRICE_VOLUME","description":"Sector/market/volatility-residualized volume activity.","table":"flow_market_learning_panel_v4","fields":["volume_residual_z"],"formula":"volume_residual_z","direction":1,"threshold":"XSEC_PERCENT_RANK_BOTTOM_20_TOP_80","history":20,"eligible":true,"interact":true,"expected":"Higher abnormal volume predicts stronger absolute continuation; positive tail tested."},
    {"id":"PV_PRICE_VOLUME_CONFIRMATION","family":"PRICE_VOLUME","description":"Positive 5-session return confirmed by abnormal volume.","table":"flow_market_learning_panel_v4","fields":["return_5d_pct","volume_residual_z"],"formula":"greatest(return_5d_pct,0)*greatest(volume_residual_z,0)","direction":1,"threshold":"XSEC_PERCENT_RANK_BOTTOM_20_TOP_80","history":20,"eligible":true,"interact":true,"expected":"Joint positive price and volume predicts positive forward alpha."},
    {"id":"PV_PRICE_VOLUME_DIVERGENCE","family":"PRICE_VOLUME","description":"Price advance without volume confirmation.","table":"flow_market_learning_panel_v4","fields":["return_5d_pct","volume_residual_z"],"formula":"greatest(return_5d_pct,0)*greatest(-volume_residual_z,0)","direction":-1,"threshold":"XSEC_PERCENT_RANK_BOTTOM_20_TOP_80","history":20,"eligible":true,"interact":false,"expected":"Stronger divergence predicts weaker forward alpha."},
    {"id":"PV_BREAKOUT_20D","family":"PRICE_VOLUME","description":"Close proximity to the trailing 20-session high.","table":"flow_market_learning_panel_v4","fields":["close_vs_20d_high_pct"],"formula":"close_vs_20d_high_pct","direction":1,"threshold":"RAW_TOP_GE_-0_25_PCT_BOTTOM_LE_-8_PCT","history":20,"eligible":true,"interact":true,"expected":"Confirmed proximity to/new high predicts continuation."},
    {"id":"PV_BREAKOUT_RETEST","family":"PRICE_VOLUME","description":"Breakout followed by a controlled retest.","table":"UNAVAILABLE_FROZEN_SEQUENCE_FEATURE","fields":[],"formula":"requires preregistered multi-session event state not present in v1 source","direction":1,"threshold":"NOT_FROZEN_NO_VALID_SOURCE","history":40,"eligible":false,"interact":false,"pit":false,"revision":false,"availability":"INSUFFICIENT_EVIDENCE","expected":"No claim in Phase 1."},
    {"id":"PV_RECLAIM","family":"PRICE_VOLUME","description":"Recovery above a previously lost support level.","table":"UNAVAILABLE_FROZEN_SUPPORT_STATE","fields":[],"formula":"not computed","direction":1,"threshold":"NOT_FROZEN_NO_VALID_SOURCE","history":40,"eligible":false,"interact":false,"pit":false,"revision":false,"availability":"INSUFFICIENT_EVIDENCE","expected":"No claim in Phase 1."},
    {"id":"PV_FAILED_BREAKOUT","family":"PRICE_VOLUME","description":"Breakout that closes back below its frozen reference level.","table":"UNAVAILABLE_FROZEN_SEQUENCE_FEATURE","fields":[],"formula":"not computed","direction":-1,"threshold":"NOT_FROZEN_NO_VALID_SOURCE","history":40,"eligible":false,"interact":false,"pit":false,"revision":false,"availability":"INSUFFICIENT_EVIDENCE","expected":"No claim in Phase 1."},
    {"id":"PV_RELATIVE_MOMENTUM_20D","family":"PRICE_VOLUME","description":"Stock 20-session return minus IHSG 20-session return.","table":"flow_market_learning_panel_v4+flow_official_index_summary","fields":["return_20d_pct","COMPOSITE.close"],"formula":"stock_return_20d-ihsg_return_20d","direction":1,"threshold":"XSEC_PERCENT_RANK_BOTTOM_20_TOP_80","history":20,"eligible":true,"interact":false,"expected":"Positive relative momentum predicts positive forward alpha."},
    {"id":"PV_VOLATILITY_EXPANSION","family":"PRICE_VOLUME","description":"Current true-range proxy relative to trailing 20-session range.","table":"flow_market_learning_panel_v4","fields":["volatility_range_pct"],"formula":"volatility_range_pct/nullif(avg20(volatility_range_pct),0)","direction":1,"threshold":"RAW_BOTTOM_0_75_TOP_1_50","history":20,"eligible":true,"interact":false,"expected":"Expansion predicts larger forward moves; positive-alpha direction is a hypothesis."},
    {"id":"PV_VOLATILITY_CONTRACTION","family":"PRICE_VOLUME","description":"Inverse of range expansion.","table":"flow_market_learning_panel_v4","fields":["volatility_range_pct"],"formula":"-volatility_range_pct/nullif(avg20(volatility_range_pct),0)","direction":1,"threshold":"XSEC_PERCENT_RANK_BOTTOM_20_TOP_80","history":20,"eligible":true,"interact":false,"expected":"Contraction may precede positive expansion; association tested without causal claim."},
    {"id":"PV_LIQUIDITY_CONDITION","family":"PRICE_VOLUME","description":"Cross-sectional market turnover share.","table":"flow_market_learning_panel_v4","fields":["market_turnover_share_pct"],"formula":"ln(1+market_turnover_share_pct)","direction":1,"threshold":"XSEC_PERCENT_RANK_BOTTOM_20_TOP_80","history":20,"eligible":true,"interact":false,"expected":"Better liquidity supports more robust forward alpha."},

    {"id":"MKT_IHSG_REGIME_20D","family":"MARKET_SECTOR","description":"IHSG trailing 20-session return regime.","table":"flow_official_index_summary","fields":["trade_date","index_code","close"],"formula":"100*(COMPOSITE.close/lag20(close)-1)","direction":1,"threshold":"RAW_BOTTOM_LE_-3_TOP_GE_3_PCT","history":20,"eligible":true,"interact":false,"expected":"Risk-on market regime supports positive stock alpha."},
    {"id":"MKT_SECTOR_REGIME_20D","family":"MARKET_SECTOR","description":"Sector-index trailing 20-session regime.","table":"flow_sector_index_map_v4+flow_official_index_summary","fields":["sector","index_code","close"],"formula":"100*(sector_close/lag20(sector_close)-1)","direction":1,"threshold":"RAW_BOTTOM_LE_-3_TOP_GE_3_PCT","history":20,"eligible":false,"interact":false,"pit":false,"revision":false,"availability":"CURRENT_SECTOR_CLASSIFICATION_NOT_HISTORICAL","expected":"Blocked until PIT sector membership exists."},
    {"id":"MKT_SECTOR_RELATIVE_STRENGTH_20D","family":"MARKET_SECTOR","description":"Sector 20-session return minus IHSG return.","table":"flow_sector_index_map_v4+flow_official_index_summary","fields":["sector","index_code","close"],"formula":"sector_return_20d-ihsg_return_20d","direction":1,"threshold":"XSEC_PERCENT_RANK_BOTTOM_20_TOP_80","history":20,"eligible":false,"interact":true,"pit":false,"revision":false,"availability":"CURRENT_SECTOR_CLASSIFICATION_NOT_HISTORICAL","expected":"Blocked until PIT sector membership exists."},
    {"id":"MKT_SECTOR_ROTATION_5V20","family":"MARKET_SECTOR","description":"Sector 5-session relative strength minus 20-session relative strength.","table":"flow_sector_index_map_v4+flow_official_index_summary","fields":["sector","index_code","close"],"formula":"sector_rs_5d-sector_rs_20d","direction":1,"threshold":"XSEC_PERCENT_RANK_BOTTOM_20_TOP_80","history":20,"eligible":false,"interact":false,"pit":false,"revision":false,"availability":"CURRENT_SECTOR_CLASSIFICATION_NOT_HISTORICAL","expected":"Blocked until PIT sector membership exists."},
    {"id":"MKT_BREADTH_20D","family":"MARKET_SECTOR","description":"Same-date market fraction of stocks above their trailing 20-session mean.","table":"flow_market_learning_panel_v4","fields":["close","as_of_date"],"formula":"avg(close>=avg20(close)) across signal-date universe","direction":1,"threshold":"RAW_BOTTOM_LE_0_35_TOP_GE_0_65","history":20,"eligible":true,"interact":false,"expected":"Broad participation supports positive forward alpha."},
    {"id":"MKT_RISK_ON_CONTEXT","family":"MARKET_SECTOR","description":"Bounded confluence of IHSG regime and market breadth.","table":"flow_official_index_summary+flow_market_learning_panel_v4","fields":["COMPOSITE.close","close"],"formula":"mean(percent_rank(ihsg_return_20d),market_breadth_20d)","direction":1,"threshold":"RAW_BOTTOM_0_35_TOP_0_65","history":20,"eligible":true,"interact":false,"expected":"Risk-on context supports positive forward alpha."},
    {"id":"MKT_RELATIVE_PERF_SECTOR_20D","family":"MARKET_SECTOR","description":"Stock return relative to its sector index.","table":"flow_market_learning_panel_v4+flow_official_index_summary","fields":["return_20d_pct","sector_index.close"],"formula":"stock_return_20d-sector_return_20d","direction":1,"threshold":"XSEC_PERCENT_RANK_BOTTOM_20_TOP_80","history":20,"eligible":false,"interact":false,"pit":false,"revision":false,"availability":"CURRENT_SECTOR_CLASSIFICATION_NOT_HISTORICAL","expected":"Blocked until PIT sector membership exists."},
    {"id":"MKT_RELATIVE_PERF_IHSG_20D","family":"MARKET_SECTOR","description":"Alias candidate suppressed because PV_RELATIVE_MOMENTUM_20D is equivalent.","table":"flow_market_learning_panel_v4+flow_official_index_summary","fields":["return_20d_pct","COMPOSITE.close"],"formula":"equivalent to PV_RELATIVE_MOMENTUM_20D; no duplicate evaluation","direction":1,"threshold":"EQUIVALENT_DRIVER_SUPPRESSED","history":20,"eligible":false,"interact":false,"availability":"EQUIVALENT_DRIVER_SUPPRESSED","expected":"No duplicate hypothesis test."},

    {"id":"TECH_BOS_20D","family":"TECHNICAL_STRUCTURE","description":"Close breaks the prior 20-session high.","table":"flow_official_stock_summary","fields":["close","high","trade_date"],"formula":"close>max(high) over rows 20 preceding to 1 preceding","direction":1,"threshold":"BINARY_TRUE_VS_FALSE","history":21,"eligible":true,"interact":true,"expected":"Bullish break of structure predicts continuation."},
    {"id":"TECH_CHOCH","family":"TECHNICAL_STRUCTURE","description":"Five-session break following negative 20-session trend.","table":"flow_official_stock_summary","fields":["close","high","trade_date"],"formula":"return_20d<0 and close>max(high) over prior 5 sessions","direction":1,"threshold":"BINARY_TRUE_VS_FALSE","history":21,"eligible":true,"interact":false,"expected":"Bullish character change predicts reversal alpha."},
    {"id":"TECH_LIQUIDITY_SWEEP_20D","family":"TECHNICAL_STRUCTURE","description":"Low sweeps the prior 20-session low and closes back above it.","table":"flow_official_stock_summary","fields":["low","close","trade_date"],"formula":"low<min(low prior20) and close>min(low prior20)","direction":1,"threshold":"BINARY_TRUE_VS_FALSE","history":21,"eligible":true,"interact":false,"expected":"Bullish sweep predicts reversal alpha."},
    {"id":"TECH_FVG_BULLISH","family":"TECHNICAL_STRUCTURE","description":"Three-bar bullish fair-value-gap proxy.","table":"flow_official_stock_summary","fields":["high","low","trade_date"],"formula":"low>lag(high,2)","direction":1,"threshold":"BINARY_TRUE_VS_FALSE","history":3,"eligible":true,"interact":false,"expected":"Bullish displacement gap predicts continuation."},
    {"id":"TECH_ORDER_BLOCK_PROXY","family":"TECHNICAL_STRUCTURE","description":"Order-block proxy requires a separately validated deterministic state machine.","table":"UNAVAILABLE_FROZEN_STRUCTURE_STATE","fields":[],"formula":"not computed","direction":0,"threshold":"NOT_FROZEN_NO_VALID_SOURCE","history":40,"eligible":false,"interact":false,"pit":false,"revision":false,"availability":"INSUFFICIENT_EVIDENCE","expected":"No claim in Phase 1."},
    {"id":"TECH_DISPLACEMENT","family":"TECHNICAL_STRUCTURE","description":"One-session return magnitude relative to trailing 20-session volatility.","table":"flow_market_learning_panel_v4","fields":["return_1d_pct"],"formula":"return_1d_pct/nullif(stddev20(return_1d_pct),0)","direction":1,"threshold":"XSEC_PERCENT_RANK_BOTTOM_20_TOP_80","history":20,"eligible":true,"interact":false,"expected":"Positive displacement predicts continuation."},
    {"id":"TECH_TREND_STRUCTURE","family":"TECHNICAL_STRUCTURE","description":"Positive 20-session return with close above trailing mean.","table":"flow_market_learning_panel_v4","fields":["return_20d_pct","close"],"formula":"0.5*rank(return_20d_pct)+0.5*(close>=avg20(close))","direction":1,"threshold":"RAW_BOTTOM_0_35_TOP_0_65","history":20,"eligible":true,"interact":true,"expected":"Aligned trend structure predicts positive forward alpha."},
    {"id":"TECH_EMA_STRUCTURE","family":"TECHNICAL_STRUCTURE","description":"EMA ordering candidate.","table":"UNAVAILABLE_FROZEN_EMA_STATE","fields":[],"formula":"not computed in v1; SMA proxy is not silently substituted","direction":1,"threshold":"NOT_FROZEN_NO_VALID_SOURCE","history":60,"eligible":false,"interact":false,"pit":false,"revision":false,"availability":"INSUFFICIENT_EVIDENCE","expected":"No claim in Phase 1."},
    {"id":"TECH_PULLBACK_CONTINUATION","family":"TECHNICAL_STRUCTURE","description":"Positive 20-session trend with a controlled negative 5-session pullback.","table":"flow_market_learning_panel_v4","fields":["return_5d_pct","return_20d_pct","close_vs_20d_high_pct"],"formula":"return_20d_pct>0 and return_5d_pct between -5 and 0 and close_vs_20d_high_pct>-10","direction":1,"threshold":"BINARY_TRUE_VS_FALSE","history":20,"eligible":true,"interact":false,"expected":"Controlled pullback predicts trend continuation."},
    {"id":"TECH_BREAKOUT_RETEST","family":"TECHNICAL_STRUCTURE","description":"Alias suppressed because PV_BREAKOUT_RETEST owns the definition.","table":"UNAVAILABLE_FROZEN_SEQUENCE_FEATURE","fields":[],"formula":"equivalent alias; no duplicate evaluation","direction":1,"threshold":"EQUIVALENT_DRIVER_SUPPRESSED","history":40,"eligible":false,"interact":false,"pit":false,"revision":false,"availability":"EQUIVALENT_DRIVER_SUPPRESSED","expected":"No duplicate hypothesis test."},
    {"id":"TECH_REVERSAL_ACCUMULATION","family":"TECHNICAL_STRUCTURE","description":"CHOCH with positive foreign accumulation; registered as a composite diagnostic only.","table":"flow_official_stock_summary+flow_market_learning_panel_v4","fields":["close","high","foreign_net_volume_pct"],"formula":"TECH_CHOCH and foreign_net_volume_pct>0","direction":1,"threshold":"BINARY_TRUE_VS_FALSE","history":21,"eligible":true,"interact":false,"expected":"Reversal plus accumulation predicts positive forward alpha."},

    {"id":"FIN_BALANCE","family":"FINANCIAL","description":"PIT balance-sheet resilience score; Gate 9 is discovery evidence, not independent confirmation.","table":"flow_financial_shadow_panel_v5","fields":["balance_score","financial_state","current_filing_id"],"formula":"balance_score from FINANCIAL_EVIDENCE_V5_PIT_SHADOW_GATE8_1","direction":1,"threshold":"RAW_BOTTOM_20_TOP_80","history":2,"eligible":true,"interact":true,"expected":"Higher balance resilience predicts positive forward alpha."},
    {"id":"FIN_CASHFLOW","family":"FINANCIAL","description":"PIT cash-flow quality score.","table":"flow_financial_shadow_panel_v5","fields":["cashflow_score","feature_states","current_filing_id"],"formula":"cashflow_score from FINANCIAL_EVIDENCE_V5_PIT_SHADOW_GATE8_1","direction":1,"threshold":"RAW_BOTTOM_20_TOP_80","history":2,"eligible":true,"interact":false,"expected":"Higher cash-flow quality predicts positive forward alpha."},
    {"id":"FIN_GROWTH","family":"FINANCIAL","description":"PIT year-over-year growth score.","table":"flow_financial_shadow_panel_v5","fields":["growth_score","feature_states","current_filing_id","prior_filing_id"],"formula":"growth_score from FINANCIAL_EVIDENCE_V5_PIT_SHADOW_GATE8_1","direction":1,"threshold":"RAW_BOTTOM_20_TOP_80","history":2,"eligible":true,"interact":false,"expected":"Higher growth predicts positive forward alpha."},
    {"id":"FIN_QUALITY","family":"FINANCIAL","description":"PIT profitability quality score.","table":"flow_financial_shadow_panel_v5","fields":["quality_score","feature_states","current_filing_id"],"formula":"quality_score from FINANCIAL_EVIDENCE_V5_PIT_SHADOW_GATE8_1","direction":1,"threshold":"RAW_BOTTOM_20_TOP_80","history":2,"eligible":true,"interact":false,"expected":"Higher quality predicts positive forward alpha."},

    {"id":"OWNERSHIP_CONCENTRATION","family":"OWNERSHIP_FREE_FLOAT","description":"Verified controller ownership percentage available as of signal date.","table":"flow_official_shareholder_profiles","fields":["observed_on","ownership_percentage","is_controller"],"formula":"sum(controller ownership_percentage) as of signal date","direction":0,"threshold":"XSEC_PERCENT_RANK_BOTTOM_20_TOP_80_NON_DIRECTIONAL","history":2,"eligible":false,"interact":false,"availability":"ONLY_3_RECENT_SNAPSHOT_DATES","expected":"Non-directional until enough PIT snapshots exist."},
    {"id":"OWNERSHIP_CHANGE","family":"OWNERSHIP_FREE_FLOAT","description":"Change in verified controller ownership between PIT snapshots.","table":"flow_official_shareholder_profiles","fields":["observed_on","ownership_percentage","holder_identity_hash"],"formula":"current controller pct-prior controller pct","direction":1,"threshold":"XSEC_PERCENT_RANK_BOTTOM_20_TOP_80","history":2,"eligible":false,"interact":false,"availability":"ONLY_3_RECENT_SNAPSHOT_DATES","expected":"Insufficient independent history."},
    {"id":"MAJOR_HOLDER_CHANGE","family":"OWNERSHIP_FREE_FLOAT","description":"Change in verified major-holder percentage.","table":"flow_major_holder_ownership_evidence_v5","fields":["effective_at","holder_identity_hash","ownership_percentage"],"formula":"current major-holder pct-prior pct","direction":0,"threshold":"NON_DIRECTIONAL_EVENT","history":2,"eligible":false,"interact":false,"availability":"INSUFFICIENT_PIT_HISTORY","expected":"No automatic bullish or bearish assumption."},
    {"id":"FREE_FLOAT_CHARACTERISTICS","family":"OWNERSHIP_FREE_FLOAT","description":"Regulatory free-float characteristics; tradable shares are not substituted.","table":"UNAVAILABLE_REGULATORY_FREE_FLOAT_HISTORY","fields":[],"formula":"not computed; tradable_shares/listed_shares is not regulatory free float","direction":0,"threshold":"NOT_FROZEN_NO_VALID_SOURCE","history":2,"eligible":false,"interact":false,"pit":false,"revision":false,"availability":"INSUFFICIENT_EVIDENCE","expected":"No claim in Phase 1."},
    {"id":"OWNERSHIP_ACCUMULATION_DISTRIBUTION","family":"OWNERSHIP_FREE_FLOAT","description":"Directional multi-snapshot ownership change.","table":"flow_official_shareholder_profiles","fields":["observed_on","holder_identity_hash","ownership_percentage"],"formula":"holder-matched ownership delta","direction":1,"threshold":"XSEC_PERCENT_RANK_BOTTOM_20_TOP_80","history":3,"eligible":false,"interact":false,"availability":"ONLY_3_RECENT_SNAPSHOT_DATES","expected":"Insufficient independent history."},

    {"id":"EVENT_RIGHTS_ISSUE","family":"CORPORATE_EVENT","description":"PIT rights-issue announcement indicator.","event":"RIGHTS_ISSUE"},
    {"id":"EVENT_BUYBACK","family":"CORPORATE_EVENT","description":"PIT buyback announcement indicator.","event":"BUYBACK"},
    {"id":"EVENT_DIVIDEND","family":"CORPORATE_EVENT","description":"PIT dividend announcement indicator.","event":"DIVIDEND"},
    {"id":"EVENT_INSIDER_TRANSACTION","family":"CORPORATE_EVENT","description":"PIT insider-transaction announcement indicator.","event":"INSIDER_TRANSACTION"},
    {"id":"EVENT_RUPS","family":"CORPORATE_EVENT","description":"PIT shareholder-meeting announcement indicator.","event":"RUPS"},
    {"id":"EVENT_MANAGEMENT_CHANGE","family":"CORPORATE_EVENT","description":"PIT management-change announcement indicator.","event":"MANAGEMENT_CHANGE"},
    {"id":"EVENT_CAPITAL_RAISING","family":"CORPORATE_EVENT","description":"PIT capital-raising announcement indicator.","event":"CAPITAL_RAISING"},
    {"id":"EVENT_DILUTION","family":"CORPORATE_EVENT","description":"PIT dilution announcement indicator.","event":"DILUTION"},
    {"id":"EVENT_MATERIAL_CONTRACT","family":"CORPORATE_EVENT","description":"PIT material-contract announcement indicator.","event":"MATERIAL_CONTRACT"},
    {"id":"EVENT_CAPEX","family":"CORPORATE_EVENT","description":"PIT capex announcement indicator.","event":"CAPEX"},
    {"id":"EVENT_GUIDANCE","family":"CORPORATE_EVENT","description":"PIT guidance announcement indicator.","event":"GUIDANCE"},
    {"id":"EVENT_EARNINGS_RELEASE","family":"CORPORATE_EVENT","description":"PIT earnings-release announcement indicator.","event":"EARNINGS_RELEASE"},
    {"id":"EVENT_RESTRUCTURING","family":"CORPORATE_EVENT","description":"PIT restructuring announcement indicator.","event":"RESTRUCTURING"},

    {"id":"LIQ_ADTV20","family":"LIQUIDITY_TRADABILITY","description":"Trailing 20-session average daily traded value.","table":"flow_market_learning_panel_v4","fields":["traded_value"],"formula":"avg20(traded_value)","direction":1,"threshold":"XSEC_PERCENT_RANK_BOTTOM_20_TOP_80","history":20,"eligible":true,"interact":false,"expected":"Higher ADTV predicts more robust forward alpha."},
    {"id":"LIQ_TURNOVER","family":"LIQUIDITY_TRADABILITY","description":"Stock share of same-date market turnover.","table":"flow_market_learning_panel_v4","fields":["market_turnover_share_pct"],"formula":"market_turnover_share_pct","direction":1,"threshold":"XSEC_PERCENT_RANK_BOTTOM_20_TOP_80","history":1,"eligible":true,"interact":false,"expected":"Higher turnover improves tradability and robustness."},
    {"id":"LIQ_ILLIQUIDITY_AMIHUD","family":"LIQUIDITY_TRADABILITY","description":"Absolute return per unit traded value.","table":"flow_market_learning_panel_v4","fields":["return_1d_pct","traded_value"],"formula":"abs(return_1d_pct)/nullif(traded_value,0)","direction":-1,"threshold":"XSEC_PERCENT_RANK_BOTTOM_20_TOP_80","history":20,"eligible":true,"interact":false,"expected":"Higher illiquidity predicts less robust forward alpha."},
    {"id":"LIQ_PRICE_IMPACT_PROXY","family":"LIQUIDITY_TRADABILITY","description":"Daily range per unit log traded value.","table":"flow_market_learning_panel_v4","fields":["volatility_range_pct","traded_value"],"formula":"volatility_range_pct/nullif(ln(1+traded_value),0)","direction":-1,"threshold":"XSEC_PERCENT_RANK_BOTTOM_20_TOP_80","history":20,"eligible":true,"interact":false,"expected":"Higher price impact predicts less robust alpha."},
    {"id":"LIQ_LOW_FLOAT_RISK","family":"LIQUIDITY_TRADABILITY","description":"Regulatory low-float risk; tradable shares are not substituted.","table":"UNAVAILABLE_REGULATORY_FREE_FLOAT_HISTORY","fields":[],"formula":"not computed","direction":-1,"threshold":"NOT_FROZEN_NO_VALID_SOURCE","history":2,"eligible":false,"interact":false,"pit":false,"revision":false,"availability":"INSUFFICIENT_EVIDENCE","expected":"No claim in Phase 1."},
    {"id":"LIQ_LIMIT_DISTORTION","family":"LIQUIDITY_TRADABILITY","description":"Limit-up/limit-down distortion requires historical price-band rules.","table":"UNAVAILABLE_HISTORICAL_PRICE_BAND_RULES","fields":[],"formula":"not computed","direction":-1,"threshold":"NOT_FROZEN_NO_VALID_SOURCE","history":20,"eligible":false,"interact":false,"pit":false,"revision":false,"availability":"INSUFFICIENT_EVIDENCE","expected":"No claim in Phase 1."},
    {"id":"LIQ_TRADABILITY_CONSTRAINT","family":"LIQUIDITY_TRADABILITY","description":"Zero volume or zero frequency on signal date.","table":"flow_market_learning_panel_v4","fields":["volume","frequency","traded_value"],"formula":"(volume=0 or frequency=0 or traded_value=0)::int","direction":-1,"threshold":"BINARY_TRUE_VS_FALSE","history":1,"eligible":true,"interact":false,"expected":"Trading constraints predict less robust forward alpha."}
  ]$drivers$::jsonb) as x(
    id text,family text,description text,"table" text,fields jsonb,formula text,direction smallint,
    threshold text,history integer,eligible boolean,interact boolean,pit boolean,revision boolean,
    availability text,expected text,event text
  )
)
insert into public.flow_driver_registry_v1(
  registry_version,driver_id,family,description,raw_source,source_table,source_fields,
  mathematical_definition,direction_hypothesis,threshold_definition,update_frequency,
  source_timestamp,effective_availability_rule,pit_safe,revision_safe,historical_availability,
  minimum_history_sessions,sector_applicability,liquidity_applicability,missing_data_semantics,
  stale_definition,invalid_definition,not_applicable_rule,horizon_candidates,expected_relationship,
  promotion_eligibility,interaction_eligibility,evaluation_eligible,frozen_at,production_influence_enabled
)
select
  'IDX_DRIVER_REGISTRY_GATE10_V1',id,family,description,'REUSED_CANONICAL_EVIDENCE',
  coalesce("table",'flow_capital_action_evidence'),
  coalesce(fields,jsonb_build_array('event_type','publication_date','observed_on','source_verified')),
  coalesce(formula,format('event_type=%s and publication_date<=signal_date',event)),coalesce(direction,0),
  coalesce(threshold,'EVENT_PRESENT_VS_ABSENT_NO_DIRECTIONAL_PRIOR'),'END_OF_DAY_OR_DISCLOSURE',
  case when family='FINANCIAL' then 'published_at' when family='CORPORATE_EVENT' then 'publication_date' else 'as_of_date/trade_date' end,
  case when family='FINANCIAL' then 'available_from_date<=signal_date; publication after 16:15 WIB shifts to next trading date'
       when family='CORPORATE_EVENT' then 'publication_date<=signal_date; fail INVALID when publication date is null'
       else 'official end-of-day evidence is available only after 16:15 WIB on trade_date; signal is evaluated after close' end,
  coalesce(pit,case when family='CORPORATE_EVENT' then false else true end),
  coalesce(revision,case when family='CORPORATE_EVENT' then false else true end),
  coalesce(availability,case when family='CORPORATE_EVENT' then 'PUBLICATION_DATE_NULL_IN_CANONICAL_SOURCE; BLOCKED' else '2025-08-01_TO_2026-09-08' end),
  coalesce(history,0),'ALL; financial sector NOT_APPLICABLE rules inherited from Gate 8 feature_states',
  'All liquidity buckets; robustness must be reported separately',
  'MISSING; never map to neutral 50 or carry forward silently',
  case when family='FINANCIAL' then 'Gate 8 filing staleness contract' else 'more than 5 trading sessions after last expected daily observation' end,
  'INVALID when source_verified=false, PIT rule fails, value is non-finite, or revision identity is unresolved',
  'NOT_APPLICABLE only for explicit economic/source applicability; never used as neutral',
  array[5,20,60],coalesce(expected,'Event sign is not assumed; estimate predictive association only.'),
  case when coalesce(eligible,false) then 'PHASE2_RESEARCH_CANDIDATE_ONLY' else 'NOT_ELIGIBLE_PHASE1' end,
  coalesce(interact,false),coalesce(eligible,false),statement_timestamp(),false
from d
on conflict(registry_version,driver_id) do nothing;

create table if not exists public.flow_driver_dependency_matrix_v1 (
  registry_version text not null,
  driver_id text not null,
  dependency_no smallint not null,
  source_relation text not null,
  source_fields jsonb not null,
  equivalent_existing_object text,
  reuse_decision text not null,
  pit_risk text not null,
  dependency_state text not null,
  primary key(registry_version,driver_id,dependency_no),
  foreign key(registry_version,driver_id) references public.flow_driver_registry_v1(registry_version,driver_id)
);

insert into public.flow_driver_dependency_matrix_v1
select registry_version,driver_id,1,source_table,source_fields,
  case when source_table like 'flow_%' then source_table end,
  case when source_table like 'flow_%' then 'REUSE_CANONICAL_NO_DUPLICATE_SOURCE' else 'FAIL_CLOSED_NO_SOURCE_SUBSTITUTION' end,
  case when pit_safe then 'NONE_WITH_FROZEN_AVAILABILITY_RULE' else 'BLOCKED_UNRESOLVED_PIT_OR_HISTORY' end,
  case when evaluation_eligible then 'READY' else historical_availability end
from public.flow_driver_registry_v1 where registry_version='IDX_DRIVER_REGISTRY_GATE10_V1'
on conflict do nothing;

create table if not exists public.flow_driver_interaction_registry_v1 (
  registry_version text not null,
  interaction_id text not null,
  family text not null,
  component_driver_ids text[] not null,
  economic_rationale text not null,
  deterministic_formula text not null,
  direction_hypothesis smallint not null check(direction_hypothesis in (-1,1)),
  threshold_definition text not null,
  minimum_coverage_pct numeric not null,
  minimum_sample_size integer not null,
  sector_applicability text not null,
  horizon_candidates integer[] not null check(horizon_candidates <@ array[5,20,60]::integer[]),
  preregistered_acceptance_rule text not null,
  frozen_at timestamptz not null,
  production_influence_enabled boolean not null default false check(production_influence_enabled=false),
  primary key(registry_version,interaction_id)
);

insert into public.flow_driver_interaction_registry_v1 values
('IDX_DRIVER_REGISTRY_GATE10_V1','INT_FLOW_SECTOR','FLOW+SECTOR',array['FLOW_FOREIGN_ACCUMULATION','MKT_SECTOR_RELATIVE_STRENGTH_20D'],'Accumulation is stronger when its sector leads.','least(oriented component normalized values)',1,'ALL_COMPONENTS_GE_0_80',10,100,'Requires PIT sector membership',array[5,20,60],'at least 12 valid OOS cells; >=66.67% positive; held-out and forward lift positive; incremental alpha lift >=0.25/0.50/1.00 pct for 5/20/60D',statement_timestamp(),false),
('IDX_DRIVER_REGISTRY_GATE10_V1','INT_FLOW_TECHNICAL','FLOW+TECHNICAL',array['FLOW_FOREIGN_ACCUMULATION','TECH_TREND_STRUCTURE'],'Flow aligned with structure may persist.','least(oriented component normalized values)',1,'ALL_COMPONENTS_GE_0_80',10,100,'All sectors',array[5,20,60],'at least 12 valid OOS cells; >=66.67% positive; held-out and forward lift positive; incremental alpha lift >=0.25/0.50/1.00 pct for 5/20/60D',statement_timestamp(),false),
('IDX_DRIVER_REGISTRY_GATE10_V1','INT_FLOW_PRICE_VOLUME','FLOW+PRICE_VOLUME',array['FLOW_FOREIGN_ACCUMULATION','PV_PRICE_VOLUME_CONFIRMATION'],'Verified flow with price-volume confirmation may improve persistence.','least(oriented component normalized values)',1,'ALL_COMPONENTS_GE_0_80',10,100,'All sectors',array[5,20,60],'at least 12 valid OOS cells; >=66.67% positive; held-out and forward lift positive; incremental alpha lift >=0.25/0.50/1.00 pct for 5/20/60D',statement_timestamp(),false),
('IDX_DRIVER_REGISTRY_GATE10_V1','INT_FLOW_FIN_BALANCE','FLOW+FIN_BALANCE',array['FLOW_FOREIGN_ACCUMULATION','FIN_BALANCE'],'Flow backed by balance resilience may have higher quality.','least(oriented component normalized values)',1,'ALL_COMPONENTS_GE_0_80',8,75,'Financial applicability inherited from Gate 8',array[5,20,60],'at least 12 valid OOS cells; >=66.67% positive; held-out and forward lift positive; incremental alpha lift >=0.25/0.50/1.00 pct for 5/20/60D',statement_timestamp(),false),
('IDX_DRIVER_REGISTRY_GATE10_V1','INT_SECTOR_TECHNICAL','SECTOR+TECHNICAL',array['MKT_SECTOR_RELATIVE_STRENGTH_20D','TECH_TREND_STRUCTURE'],'Sector leadership may validate stock structure.','least(oriented component normalized values)',1,'ALL_COMPONENTS_GE_0_80',10,100,'Requires PIT sector membership',array[5,20,60],'same frozen 12-cell consistency and incremental-lift rule',statement_timestamp(),false),
('IDX_DRIVER_REGISTRY_GATE10_V1','INT_SECTOR_PRICE_VOLUME','SECTOR+PRICE_VOLUME',array['MKT_SECTOR_RELATIVE_STRENGTH_20D','PV_PRICE_VOLUME_CONFIRMATION'],'Sector leadership may strengthen price-volume confirmation.','least(oriented component normalized values)',1,'ALL_COMPONENTS_GE_0_80',10,100,'Requires PIT sector membership',array[5,20,60],'same frozen 12-cell consistency and incremental-lift rule',statement_timestamp(),false),
('IDX_DRIVER_REGISTRY_GATE10_V1','INT_TECHNICAL_FIN_BALANCE','TECHNICAL+FIN_BALANCE',array['TECH_TREND_STRUCTURE','FIN_BALANCE'],'Structure with resilient balance evidence may be more durable.','least(oriented component normalized values)',1,'ALL_COMPONENTS_GE_0_80',8,75,'Financial applicability inherited from Gate 8',array[5,20,60],'same frozen 12-cell consistency and incremental-lift rule',statement_timestamp(),false),
('IDX_DRIVER_REGISTRY_GATE10_V1','INT_FLOW_SECTOR_TECHNICAL','FLOW+SECTOR+TECHNICAL',array['FLOW_FOREIGN_ACCUMULATION','MKT_SECTOR_RELATIVE_STRENGTH_20D','TECH_TREND_STRUCTURE'],'Three-way alignment tests breadth of confirmation.','least(oriented component normalized values)',1,'ALL_COMPONENTS_GE_0_80',5,50,'Requires PIT sector membership',array[5,20,60],'same frozen 12-cell consistency and incremental-lift rule',statement_timestamp(),false),
('IDX_DRIVER_REGISTRY_GATE10_V1','INT_FLOW_SECTOR_PRICE_VOLUME','FLOW+SECTOR+PRICE_VOLUME',array['FLOW_FOREIGN_ACCUMULATION','MKT_SECTOR_RELATIVE_STRENGTH_20D','PV_PRICE_VOLUME_CONFIRMATION'],'Flow, sector, and tape confirmation.','least(oriented component normalized values)',1,'ALL_COMPONENTS_GE_0_80',5,50,'Requires PIT sector membership',array[5,20,60],'same frozen 12-cell consistency and incremental-lift rule',statement_timestamp(),false),
('IDX_DRIVER_REGISTRY_GATE10_V1','INT_FLOW_SECTOR_FIN_BALANCE','FLOW+SECTOR+FIN_BALANCE',array['FLOW_FOREIGN_ACCUMULATION','MKT_SECTOR_RELATIVE_STRENGTH_20D','FIN_BALANCE'],'Flow, sector leadership, and balance resilience.','least(oriented component normalized values)',1,'ALL_COMPONENTS_GE_0_80',4,50,'Requires PIT sector membership and Gate 8 applicability',array[5,20,60],'same frozen 12-cell consistency and incremental-lift rule',statement_timestamp(),false),
('IDX_DRIVER_REGISTRY_GATE10_V1','INT_FLOW_TECHNICAL_FIN_BALANCE','FLOW+TECHNICAL+FIN_BALANCE',array['FLOW_FOREIGN_ACCUMULATION','TECH_TREND_STRUCTURE','FIN_BALANCE'],'Flow and structure backed by balance resilience.','least(oriented component normalized values)',1,'ALL_COMPONENTS_GE_0_80',4,50,'Financial applicability inherited from Gate 8',array[5,20,60],'same frozen 12-cell consistency and incremental-lift rule',statement_timestamp(),false),
('IDX_DRIVER_REGISTRY_GATE10_V1','INT_FLOW_SECTOR_TECHNICAL_FIN_BALANCE','FLOW+SECTOR+TECHNICAL+FIN_BALANCE',array['FLOW_FOREIGN_ACCUMULATION','MKT_SECTOR_RELATIVE_STRENGTH_20D','TECH_TREND_STRUCTURE','FIN_BALANCE'],'Maximum preregistered four-family confluence.','least(oriented component normalized values)',1,'ALL_COMPONENTS_GE_0_80',2,30,'Requires PIT sector membership and Gate 8 applicability',array[5,20,60],'same frozen 12-cell consistency and incremental-lift rule',statement_timestamp(),false)
on conflict(registry_version,interaction_id) do nothing;

create table if not exists public.flow_driver_research_policy_v1 (
  registry_version text primary key,
  panel_contract text not null,
  walkforward_contract text not null,
  benchmark_contract text not null,
  normalization_contract text not null,
  purge_rule text not null,
  horizons integer[] not null,
  fold_count_per_horizon integer not null,
  acceptance_criteria jsonb not null,
  max_interaction_budget integer not null,
  driver_count integer not null,
  interaction_count integer not null,
  registry_sha256 text not null,
  frozen_at timestamptz not null,
  candidate_registry_frozen_before_evaluation boolean not null check(candidate_registry_frozen_before_evaluation),
  production_influence_enabled boolean not null default false check(production_influence_enabled=false)
);

insert into public.flow_driver_research_policy_v1
select 'IDX_DRIVER_REGISTRY_GATE10_V1','IDX_DRIVER_WEEKLY_PIT_PANEL_V1',
  'IDX_DRIVER_PURGED_EXPANDING_WF_V1',
  'IHSG_PRIMARY__SECTOR_SECONDARY_ONLY_WITH_PIT_MEMBERSHIP',
  'SIGNAL_DATE_CROSS_SECTIONAL_PERCENT_RANK_NO_FUTURE_ROWS',
  'PURGE_TRAIN_ROWS_UNLESS_TARGET_DATE_LE_TRAIN_END',array[5,20,60],2,
  jsonb_build_object(
    'single_driver','valid_oos_cells>=15;direction_agreement>=66.67%;heldout_mean_alpha>0;forward_mean_alpha>0;positive_horizons=3;coverage>=60%',
    'interaction',jsonb_build_object(
      'rule','valid_oos_cells>=12;direction_agreement>=66.67%;heldout_and_forward_incremental_lift>0;minimum_samples_from_registry',
      'incremental_lift_threshold_pct',jsonb_build_object('5D',0.25,'20D',0.50,'60D',1.00)
    ),
    'multiple_testing','no threshold search outside TRAIN; frozen registry; VALIDATION selection only; HELDOUT and FORWARD never tune',
    'classifications',jsonb_build_array('PROMISING','WEAK','UNSTABLE','REGIME_DEPENDENT','SECTOR_SPECIFIC','LIQUIDITY_SENSITIVE','REJECTED','INSUFFICIENT_EVIDENCE')
  ),12,
  (select count(*) from public.flow_driver_registry_v1 where registry_version='IDX_DRIVER_REGISTRY_GATE10_V1'),
  (select count(*) from public.flow_driver_interaction_registry_v1 where registry_version='IDX_DRIVER_REGISTRY_GATE10_V1'),
  encode(extensions.digest(convert_to((select string_agg(to_jsonb(r)::text,E'\n' order by driver_id) from public.flow_driver_registry_v1 r where registry_version='IDX_DRIVER_REGISTRY_GATE10_V1'),'UTF8'),'sha256'),'hex'),
  statement_timestamp(),true,false
on conflict(registry_version) do nothing;

alter table public.flow_driver_state_catalog_v1 enable row level security;
alter table public.flow_driver_registry_v1 enable row level security;
alter table public.flow_driver_dependency_matrix_v1 enable row level security;
alter table public.flow_driver_interaction_registry_v1 enable row level security;
alter table public.flow_driver_research_policy_v1 enable row level security;

revoke all on public.flow_driver_state_catalog_v1,public.flow_driver_registry_v1,
  public.flow_driver_dependency_matrix_v1,public.flow_driver_interaction_registry_v1,
  public.flow_driver_research_policy_v1 from public,anon,authenticated,service_role;
grant select on public.flow_driver_state_catalog_v1,public.flow_driver_registry_v1,
  public.flow_driver_dependency_matrix_v1,public.flow_driver_interaction_registry_v1,
  public.flow_driver_research_policy_v1 to service_role;

create or replace function public.flow_driver_registry_snapshot_v1()
returns jsonb
language sql
stable
security invoker
set search_path=''
as $fn$
select jsonb_build_object(
  'registry_version',p.registry_version,'frozen_at',p.frozen_at,'registry_sha256',p.registry_sha256,
  'driver_count',(select count(*) from public.flow_driver_registry_v1 r where r.registry_version=p.registry_version),
  'family_count',(select count(distinct family) from public.flow_driver_registry_v1 r where r.registry_version=p.registry_version),
  'evaluation_eligible_drivers',(select count(*) from public.flow_driver_registry_v1 r where r.registry_version=p.registry_version and r.evaluation_eligible),
  'interaction_count',(select count(*) from public.flow_driver_interaction_registry_v1 i where i.registry_version=p.registry_version),
  'max_interaction_budget',p.max_interaction_budget,
  'candidate_registry_frozen_before_evaluation',p.candidate_registry_frozen_before_evaluation,
  'production_influence_enabled',false
)
from public.flow_driver_research_policy_v1 p
where p.registry_version='IDX_DRIVER_REGISTRY_GATE10_V1';
$fn$;

create or replace function public.flow_validate_driver_registry_v1()
returns jsonb
language sql
stable
security invoker
set search_path=''
as $fn$
with p as (select * from public.flow_driver_research_policy_v1 where registry_version='IDX_DRIVER_REGISTRY_GATE10_V1'),
c as (
  select count(*) drivers,count(distinct family) families,count(*) filter(where not production_influence_enabled) isolated
  from public.flow_driver_registry_v1 where registry_version='IDX_DRIVER_REGISTRY_GATE10_V1'
), i as (
  select count(*) interactions,count(*) filter(where not production_influence_enabled) isolated
  from public.flow_driver_interaction_registry_v1 where registry_version='IDX_DRIVER_REGISTRY_GATE10_V1'
)
select jsonb_build_object(
 'status',case when c.families=8 and c.drivers=p.driver_count and i.interactions=12 and i.interactions=p.max_interaction_budget
                    and c.isolated=c.drivers and i.isolated=i.interactions and p.candidate_registry_frozen_before_evaluation
               then 'PASS' else 'FAIL' end,
 'drivers',c.drivers,'families',c.families,'interactions',i.interactions,
 'sector_pit_fail_closed',(select count(*) from public.flow_driver_registry_v1 where registry_version=p.registry_version and family='MARKET_SECTOR' and not pit_safe and not evaluation_eligible),
 'production_influence_enabled',false
)
from p cross join c cross join i;
$fn$;

revoke all on function public.flow_driver_registry_snapshot_v1() from public,anon,authenticated;
revoke all on function public.flow_validate_driver_registry_v1() from public,anon,authenticated;
grant execute on function public.flow_driver_registry_snapshot_v1() to service_role;
grant execute on function public.flow_validate_driver_registry_v1() to service_role;

comment on table public.flow_driver_registry_v1 is 'Frozen Gate 10 predictive-driver universe. Research only; missing is never neutral.';
comment on table public.flow_driver_interaction_registry_v1 is 'Exactly twelve preregistered Gate 13 interaction families; no Cartesian mining.';
