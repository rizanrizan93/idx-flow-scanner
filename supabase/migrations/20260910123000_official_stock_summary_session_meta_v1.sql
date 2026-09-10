-- Storage remediation: normalize repeated official-stock session metadata while
-- preserving the exact logical flow_official_stock_summary contract.
-- No market values, scoring inputs, ranking policy, or promotion policy change.

DO $do$
DECLARE
  v_kind "char";
  v_rows bigint;
  v_bad_contract bigint;
  v_bad_sessions bigint;
  v_fk bigint;
  v_triggers bigint;
BEGIN
  SELECT c.relkind INTO v_kind
  FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='public' AND c.relname='flow_official_stock_summary';
  IF v_kind IS DISTINCT FROM 'r'::"char" THEN
    RAISE EXCEPTION 'official stock summary compaction denied: expected physical table, got %',v_kind;
  END IF;
  IF to_regclass('public.flow_official_stock_summary_core_v1') IS NOT NULL
     OR to_regclass('public.flow_official_stock_summary_session_meta_v1') IS NOT NULL
     OR to_regclass('public.flow_official_stock_summary_legacy_v1') IS NOT NULL THEN
    RAISE EXCEPTION 'official stock summary compaction denied: target/legacy object already exists';
  END IF;

  SELECT count(*)::bigint,
         count(*) FILTER(WHERE source<>'IDX_OFFICIAL_STOCK_SUMMARY'
                          OR NOT source_verified
                          OR source_url IS NULL
                          OR provenance_state<>'VERIFIED_OFFICIAL_IDX_STOCK_SUMMARY_RAW_PANEL'
                          OR ingested_at IS NULL)::bigint
  INTO v_rows,v_bad_contract
  FROM public.flow_official_stock_summary;
  IF v_rows<200000 OR v_bad_contract<>0 THEN
    RAISE EXCEPTION 'official stock summary compaction denied: rows %, contract violations %',v_rows,v_bad_contract;
  END IF;

  SELECT count(*)::bigint INTO v_bad_sessions
  FROM (
    SELECT trade_date
    FROM public.flow_official_stock_summary
    GROUP BY trade_date
    HAVING count(DISTINCT concat_ws('|',source,source_verified::text,source_url,provenance_state,ingested_at::text))<>1
  ) q;
  IF v_bad_sessions<>0 THEN
    RAISE EXCEPTION 'official stock summary compaction denied: % sessions have nonconstant source metadata',v_bad_sessions;
  END IF;

  SELECT count(*)::bigint INTO v_fk
  FROM pg_constraint
  WHERE contype='f'
    AND (conrelid='public.flow_official_stock_summary'::regclass
         OR confrelid='public.flow_official_stock_summary'::regclass);
  IF v_fk<>0 THEN
    RAISE EXCEPTION 'official stock summary compaction denied: % FK references exist',v_fk;
  END IF;

  SELECT count(*)::bigint INTO v_triggers
  FROM pg_trigger
  WHERE tgrelid='public.flow_official_stock_summary'::regclass AND NOT tgisinternal;
  IF v_triggers<>0 THEN
    RAISE EXCEPTION 'official stock summary compaction denied: % user triggers exist',v_triggers;
  END IF;
END
$do$;

CREATE TEMPORARY TABLE flow_official_stock_summary_compaction_stats_v1 ON COMMIT DROP AS
SELECT
  count(*)::bigint AS before_rows,
  count(DISTINCT trade_date)::bigint AS before_sessions,
  pg_total_relation_size('public.flow_official_stock_summary'::regclass)::bigint AS before_bytes,
  encode(extensions.digest(convert_to(coalesce(string_agg(
    encode(extensions.digest(convert_to(concat_ws('|',
      trade_date::text,ticker,coalesce(stock_name,''),coalesce(previous::text,''),coalesce(open::text,''),
      coalesce(high::text,''),coalesce(low::text,''),coalesce(close::text,''),coalesce(change::text,''),
      volume::text,traded_value::text,frequency::text,foreign_buy::text,foreign_sell::text,
      coalesce(listed_shares::text,''),coalesce(tradable_shares::text,''),coalesce(bid::text,''),
      coalesce(offer::text,''),coalesce(bid_volume::text,''),coalesce(offer_volume::text,''),
      coalesce(non_regular_volume::text,''),coalesce(non_regular_value::text,''),coalesce(non_regular_frequency::text,''),
      source,source_verified::text,source_url,provenance_state,ingested_at::text
    ),'UTF8'),'sha256'),'hex'),'' ORDER BY trade_date,ticker),''),'UTF8'),'sha256'),'hex') AS logical_sha256
FROM public.flow_official_stock_summary;

CREATE TEMPORARY TABLE flow_official_stock_summary_dependent_views_v1 ON COMMIT DROP AS
SELECT v.schemaname,v.viewname,v.definition,
       coalesce('security_invoker=true'=ANY(c.reloptions),false) AS security_invoker
FROM pg_views v
JOIN pg_class c ON c.relname=v.viewname
JOIN pg_namespace n ON n.oid=c.relnamespace AND n.nspname=v.schemaname
WHERE v.schemaname='public'
  AND v.definition ILIKE '%flow_official_stock_summary%';

CREATE TABLE public.flow_official_stock_summary_core_v1(
  trade_date date NOT NULL,
  ticker text NOT NULL,
  stock_name text,
  previous numeric,
  open numeric,
  high numeric,
  low numeric,
  close numeric NOT NULL,
  change numeric,
  volume numeric NOT NULL,
  traded_value numeric NOT NULL,
  frequency numeric NOT NULL,
  foreign_buy numeric NOT NULL,
  foreign_sell numeric NOT NULL,
  listed_shares numeric,
  tradable_shares numeric,
  bid numeric,
  offer numeric,
  bid_volume numeric,
  offer_volume numeric,
  non_regular_volume numeric,
  non_regular_value numeric,
  non_regular_frequency numeric,
  CONSTRAINT flow_official_stock_summary_core_v1_pkey PRIMARY KEY(trade_date,ticker)
);
CREATE INDEX flow_official_stock_summary_core_v1_date_idx
  ON public.flow_official_stock_summary_core_v1(trade_date DESC,ticker);
CREATE INDEX flow_official_stock_summary_core_v1_ticker_date_idx
  ON public.flow_official_stock_summary_core_v1(ticker,trade_date DESC);

CREATE TABLE public.flow_official_stock_summary_session_meta_v1(
  trade_date date PRIMARY KEY,
  source_url text NOT NULL,
  provenance_state text NOT NULL CHECK(provenance_state='VERIFIED_OFFICIAL_IDX_STOCK_SUMMARY_RAW_PANEL'),
  ingested_at timestamptz NOT NULL
);

INSERT INTO public.flow_official_stock_summary_core_v1(
  trade_date,ticker,stock_name,previous,open,high,low,close,change,volume,traded_value,frequency,
  foreign_buy,foreign_sell,listed_shares,tradable_shares,bid,offer,bid_volume,offer_volume,
  non_regular_volume,non_regular_value,non_regular_frequency
)
SELECT
  trade_date,ticker,stock_name,previous,open,high,low,close,change,volume,traded_value,frequency,
  foreign_buy,foreign_sell,listed_shares,tradable_shares,bid,offer,bid_volume,offer_volume,
  non_regular_volume,non_regular_value,non_regular_frequency
FROM public.flow_official_stock_summary
ORDER BY trade_date,ticker;

INSERT INTO public.flow_official_stock_summary_session_meta_v1(
  trade_date,source_url,provenance_state,ingested_at
)
SELECT trade_date,max(source_url),max(provenance_state),max(ingested_at)
FROM public.flow_official_stock_summary
GROUP BY trade_date
ORDER BY trade_date;

ANALYZE public.flow_official_stock_summary_core_v1;
ANALYZE public.flow_official_stock_summary_session_meta_v1;

DO $do$
DECLARE
  v_before_rows bigint;
  v_before_sessions bigint;
  v_core_rows bigint;
  v_meta_rows bigint;
BEGIN
  SELECT before_rows,before_sessions INTO v_before_rows,v_before_sessions
  FROM flow_official_stock_summary_compaction_stats_v1;
  SELECT count(*)::bigint INTO v_core_rows FROM public.flow_official_stock_summary_core_v1;
  SELECT count(*)::bigint INTO v_meta_rows FROM public.flow_official_stock_summary_session_meta_v1;
  IF v_core_rows<>v_before_rows OR v_meta_rows<>v_before_sessions THEN
    RAISE EXCEPTION 'official stock summary compact copy verification failed: core %/%, meta %/%',
      v_core_rows,v_before_rows,v_meta_rows,v_before_sessions;
  END IF;
END
$do$;

-- Rewrite the only verified writer so ON CONFLICT remains table-backed rather
-- than relying on view conflict inference.
CREATE OR REPLACE FUNCTION public.flow_refresh_official_idx_stock_summary(
  p_date date DEFAULT ((now() AT TIME ZONE 'Asia/Jakarta'::text))::date
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog','public','extensions'
AS $function$
DECLARE
  url text; payload jsonb; http_status integer; api_rows integer; records_total integer;
  payload_min date; payload_max date; affected integer := 0; v_ingested_at timestamptz := now();
BEGIN
  IF extract(isodow FROM p_date) NOT BETWEEN 1 AND 5 THEN RETURN 0; END IF;
  url := 'https://block.idx.id/primary/TradingSummary/GetStockSummary?length=2000&start=0&date=' || to_char(p_date,'YYYYMMDD');
  SELECT h.status,h.content::jsonb INTO http_status,payload FROM extensions.http_get(url) h;
  IF http_status<>200 THEN RAISE EXCEPTION 'IDX stock summary raw HTTP % for %',http_status,p_date; END IF;
  api_rows := coalesce(jsonb_array_length(coalesce(payload->'data','[]'::jsonb)),0);
  records_total := nullif(payload->>'recordsTotal','')::integer;
  IF api_rows=0 THEN RETURN 0; END IF;
  IF records_total IS NULL OR api_rows<>records_total THEN
    RAISE EXCEPTION 'IDX stock summary raw incomplete page for %: rows %, total %',p_date,api_rows,records_total;
  END IF;
  IF api_rows<800 THEN RAISE EXCEPTION 'IDX stock summary raw unexpectedly small for %: % rows',p_date,api_rows; END IF;
  SELECT min((x->>'Date')::date),max((x->>'Date')::date)
    INTO payload_min,payload_max FROM jsonb_array_elements(payload->'data') x;
  IF payload_min IS DISTINCT FROM p_date OR payload_max IS DISTINCT FROM p_date THEN
    RAISE EXCEPTION 'IDX stock summary raw date mismatch: requested %, got % to %',p_date,payload_min,payload_max;
  END IF;

  INSERT INTO public.flow_official_stock_summary_session_meta_v1(
    trade_date,source_url,provenance_state,ingested_at
  ) VALUES(
    p_date,url,'VERIFIED_OFFICIAL_IDX_STOCK_SUMMARY_RAW_PANEL',v_ingested_at
  )
  ON CONFLICT(trade_date) DO UPDATE SET
    source_url=excluded.source_url,
    provenance_state=excluded.provenance_state,
    ingested_at=excluded.ingested_at;

  INSERT INTO public.flow_official_stock_summary_core_v1(
    trade_date,ticker,stock_name,previous,open,high,low,close,change,volume,traded_value,frequency,
    foreign_buy,foreign_sell,listed_shares,tradable_shares,bid,offer,bid_volume,offer_volume,
    non_regular_volume,non_regular_value,non_regular_frequency
  )
  SELECT
    (x->>'Date')::date,upper(trim(x->>'StockCode')),nullif(trim(x->>'StockName'),''),
    nullif(x->>'Previous','')::numeric,nullif(x->>'OpenPrice','')::numeric,nullif(x->>'High','')::numeric,
    nullif(x->>'Low','')::numeric,nullif(x->>'Close','')::numeric,nullif(x->>'Change','')::numeric,
    coalesce(nullif(x->>'Volume','')::numeric,0),coalesce(nullif(x->>'Value','')::numeric,0),
    coalesce(nullif(x->>'Frequency','')::numeric,0),coalesce(nullif(x->>'ForeignBuy','')::numeric,0),
    coalesce(nullif(x->>'ForeignSell','')::numeric,0),nullif(x->>'ListedShares','')::numeric,
    nullif(x->>'TradebleShares','')::numeric,nullif(x->>'Bid','')::numeric,nullif(x->>'Offer','')::numeric,
    nullif(x->>'BidVolume','')::numeric,nullif(x->>'OfferVolume','')::numeric,
    nullif(x->>'NonRegularVolume','')::numeric,nullif(x->>'NonRegularValue','')::numeric,
    nullif(x->>'NonRegularFrequency','')::numeric
  FROM jsonb_array_elements(payload->'data') x
  WHERE nullif(trim(x->>'StockCode'),'') IS NOT NULL AND (x->>'Date')::date=p_date
    AND coalesce(nullif(x->>'Volume','')::numeric,0)>=0 AND coalesce(nullif(x->>'Value','')::numeric,0)>=0
    AND coalesce(nullif(x->>'Frequency','')::numeric,0)>=0 AND coalesce(nullif(x->>'ForeignBuy','')::numeric,0)>=0
    AND coalesce(nullif(x->>'ForeignSell','')::numeric,0)>=0
  ON CONFLICT(trade_date,ticker) DO UPDATE SET
    stock_name=excluded.stock_name,previous=excluded.previous,open=excluded.open,high=excluded.high,low=excluded.low,
    close=excluded.close,change=excluded.change,volume=excluded.volume,traded_value=excluded.traded_value,
    frequency=excluded.frequency,foreign_buy=excluded.foreign_buy,foreign_sell=excluded.foreign_sell,
    listed_shares=excluded.listed_shares,tradable_shares=excluded.tradable_shares,bid=excluded.bid,offer=excluded.offer,
    bid_volume=excluded.bid_volume,offer_volume=excluded.offer_volume,non_regular_volume=excluded.non_regular_volume,
    non_regular_value=excluded.non_regular_value,non_regular_frequency=excluded.non_regular_frequency;
  GET DIAGNOSTICS affected=ROW_COUNT;
  RETURN affected;
END
$function$;

ALTER TABLE public.flow_official_stock_summary RENAME TO flow_official_stock_summary_legacy_v1;

CREATE VIEW public.flow_official_stock_summary
WITH (security_invoker=true)
AS
SELECT
  c.trade_date,c.ticker,c.stock_name,c.previous,c.open,c.high,c.low,c.close,c.change,c.volume,c.traded_value,
  c.frequency,c.foreign_buy,c.foreign_sell,c.listed_shares,c.tradable_shares,c.bid,c.offer,c.bid_volume,
  c.offer_volume,c.non_regular_volume,c.non_regular_value,c.non_regular_frequency,
  'IDX_OFFICIAL_STOCK_SUMMARY'::text AS source,
  true::boolean AS source_verified,
  m.source_url,
  m.provenance_state,
  m.ingested_at
FROM public.flow_official_stock_summary_core_v1 c
JOIN public.flow_official_stock_summary_session_meta_v1 m USING(trade_date);

-- Guard generic direct DML against changing session-wide provenance from a
-- single row. The canonical refresh function writes the physical tables directly.
CREATE FUNCTION public.flow_official_stock_summary_compat_iud_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO ''
AS $fn$
DECLARE
  v_meta public.flow_official_stock_summary_session_meta_v1%ROWTYPE;
BEGIN
  IF TG_OP='DELETE' THEN
    DELETE FROM public.flow_official_stock_summary_core_v1
    WHERE trade_date=OLD.trade_date AND ticker=OLD.ticker;
    IF NOT EXISTS(SELECT 1 FROM public.flow_official_stock_summary_core_v1 WHERE trade_date=OLD.trade_date) THEN
      DELETE FROM public.flow_official_stock_summary_session_meta_v1 WHERE trade_date=OLD.trade_date;
    END IF;
    RETURN OLD;
  END IF;

  IF NEW.source IS DISTINCT FROM 'IDX_OFFICIAL_STOCK_SUMMARY'
     OR NEW.source_verified IS DISTINCT FROM true
     OR NEW.source_url IS NULL
     OR NEW.provenance_state IS DISTINCT FROM 'VERIFIED_OFFICIAL_IDX_STOCK_SUMMARY_RAW_PANEL'
     OR NEW.ingested_at IS NULL THEN
    RAISE EXCEPTION 'official stock summary compatibility write denied: provenance contract mismatch for % %',
      NEW.trade_date,NEW.ticker;
  END IF;

  SELECT * INTO v_meta
  FROM public.flow_official_stock_summary_session_meta_v1
  WHERE trade_date=NEW.trade_date;
  IF FOUND AND (v_meta.source_url IS DISTINCT FROM NEW.source_url
                OR v_meta.provenance_state IS DISTINCT FROM NEW.provenance_state
                OR v_meta.ingested_at IS DISTINCT FROM NEW.ingested_at) THEN
    RAISE EXCEPTION 'official stock summary compatibility write denied: session metadata differs for %',NEW.trade_date;
  END IF;
  IF NOT FOUND THEN
    INSERT INTO public.flow_official_stock_summary_session_meta_v1(trade_date,source_url,provenance_state,ingested_at)
    VALUES(NEW.trade_date,NEW.source_url,NEW.provenance_state,NEW.ingested_at);
  END IF;

  IF TG_OP='UPDATE' AND (OLD.trade_date IS DISTINCT FROM NEW.trade_date OR OLD.ticker IS DISTINCT FROM NEW.ticker) THEN
    RAISE EXCEPTION 'official stock summary compatibility update denied: primary key change';
  END IF;

  INSERT INTO public.flow_official_stock_summary_core_v1(
    trade_date,ticker,stock_name,previous,open,high,low,close,change,volume,traded_value,frequency,
    foreign_buy,foreign_sell,listed_shares,tradable_shares,bid,offer,bid_volume,offer_volume,
    non_regular_volume,non_regular_value,non_regular_frequency
  ) VALUES(
    NEW.trade_date,NEW.ticker,NEW.stock_name,NEW.previous,NEW.open,NEW.high,NEW.low,NEW.close,NEW.change,
    NEW.volume,NEW.traded_value,NEW.frequency,NEW.foreign_buy,NEW.foreign_sell,NEW.listed_shares,
    NEW.tradable_shares,NEW.bid,NEW.offer,NEW.bid_volume,NEW.offer_volume,NEW.non_regular_volume,
    NEW.non_regular_value,NEW.non_regular_frequency
  )
  ON CONFLICT(trade_date,ticker) DO UPDATE SET
    stock_name=excluded.stock_name,previous=excluded.previous,open=excluded.open,high=excluded.high,low=excluded.low,
    close=excluded.close,change=excluded.change,volume=excluded.volume,traded_value=excluded.traded_value,
    frequency=excluded.frequency,foreign_buy=excluded.foreign_buy,foreign_sell=excluded.foreign_sell,
    listed_shares=excluded.listed_shares,tradable_shares=excluded.tradable_shares,bid=excluded.bid,offer=excluded.offer,
    bid_volume=excluded.bid_volume,offer_volume=excluded.offer_volume,non_regular_volume=excluded.non_regular_volume,
    non_regular_value=excluded.non_regular_value,non_regular_frequency=excluded.non_regular_frequency;
  RETURN NEW;
END
$fn$;

CREATE TRIGGER flow_official_stock_summary_compat_iud_v1
INSTEAD OF INSERT OR UPDATE OR DELETE ON public.flow_official_stock_summary
FOR EACH ROW EXECUTE FUNCTION public.flow_official_stock_summary_compat_iud_v1();

ALTER TABLE public.flow_official_stock_summary_core_v1 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.flow_official_stock_summary_session_meta_v1 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.flow_official_stock_summary_core_v1,
  public.flow_official_stock_summary_session_meta_v1,public.flow_official_stock_summary
  FROM public,anon,authenticated;
GRANT SELECT,INSERT,UPDATE,DELETE ON TABLE public.flow_official_stock_summary_core_v1 TO service_role;
GRANT SELECT,INSERT,UPDATE,DELETE ON TABLE public.flow_official_stock_summary_session_meta_v1 TO service_role;
GRANT SELECT,INSERT,UPDATE,DELETE ON TABLE public.flow_official_stock_summary TO service_role;
REVOKE ALL ON FUNCTION public.flow_official_stock_summary_compat_iud_v1() FROM public,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.flow_official_stock_summary_compat_iud_v1() TO service_role;

-- Rebind all pre-existing views to the compatibility view. RESTRICT below is
-- the fail-closed guard if any dependency remains attached to the legacy table.
DO $do$
DECLARE r record;
BEGIN
  FOR r IN SELECT * FROM flow_official_stock_summary_dependent_views_v1 ORDER BY viewname LOOP
    EXECUTE format('create or replace view %I.%I as %s',r.schemaname,r.viewname,r.definition);
    IF r.security_invoker THEN
      EXECUTE format('alter view %I.%I set (security_invoker=true)',r.schemaname,r.viewname);
    END IF;
  END LOOP;
END
$do$;

DROP TABLE public.flow_official_stock_summary_legacy_v1 RESTRICT;

CREATE TABLE public.flow_official_stock_summary_compaction_manifest_v1(
  compaction_contract text PRIMARY KEY,
  before_rows bigint NOT NULL,
  logical_view_rows bigint NOT NULL,
  session_rows bigint NOT NULL,
  before_bytes bigint NOT NULL,
  core_bytes bigint NOT NULL,
  session_meta_bytes bigint NOT NULL,
  logical_sha256_before text NOT NULL CHECK(length(logical_sha256_before)=64),
  logical_sha256_after text NOT NULL CHECK(length(logical_sha256_after)=64),
  details jsonb NOT NULL,
  compacted_at timestamptz NOT NULL DEFAULT statement_timestamp(),
  production_influence_enabled boolean NOT NULL DEFAULT false CHECK(production_influence_enabled=false)
);
ALTER TABLE public.flow_official_stock_summary_compaction_manifest_v1 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.flow_official_stock_summary_compaction_manifest_v1 FROM public,anon,authenticated;
GRANT SELECT ON TABLE public.flow_official_stock_summary_compaction_manifest_v1 TO service_role;

INSERT INTO public.flow_official_stock_summary_compaction_manifest_v1(
  compaction_contract,before_rows,logical_view_rows,session_rows,before_bytes,core_bytes,session_meta_bytes,
  logical_sha256_before,logical_sha256_after,details,production_influence_enabled
)
SELECT
  'OFFICIAL_STOCK_SUMMARY_SESSION_META_V1',s.before_rows,
  (SELECT count(*) FROM public.flow_official_stock_summary),
  (SELECT count(*) FROM public.flow_official_stock_summary_session_meta_v1),
  s.before_bytes,
  pg_total_relation_size('public.flow_official_stock_summary_core_v1'::regclass),
  pg_total_relation_size('public.flow_official_stock_summary_session_meta_v1'::regclass),
  s.logical_sha256,
  encode(extensions.digest(convert_to(coalesce((SELECT string_agg(
    encode(extensions.digest(convert_to(concat_ws('|',
      q.trade_date::text,q.ticker,coalesce(q.stock_name,''),coalesce(q.previous::text,''),coalesce(q.open::text,''),
      coalesce(q.high::text,''),coalesce(q.low::text,''),coalesce(q.close::text,''),coalesce(q.change::text,''),
      q.volume::text,q.traded_value::text,q.frequency::text,q.foreign_buy::text,q.foreign_sell::text,
      coalesce(q.listed_shares::text,''),coalesce(q.tradable_shares::text,''),coalesce(q.bid::text,''),
      coalesce(q.offer::text,''),coalesce(q.bid_volume::text,''),coalesce(q.offer_volume::text,''),
      coalesce(q.non_regular_volume::text,''),coalesce(q.non_regular_value::text,''),coalesce(q.non_regular_frequency::text,''),
      q.source,q.source_verified::text,q.source_url,q.provenance_state,q.ingested_at::text
    ),'UTF8'),'sha256'),'hex'),'' ORDER BY q.trade_date,q.ticker)
    FROM public.flow_official_stock_summary q),''),'UTF8'),'sha256'),'hex'),
  jsonb_build_object(
    'canonical_market_fields_preserved',true,
    'source_and_verified_projected_as_frozen_constants',true,
    'source_url_provenance_ingested_at_normalized_per_session',true,
    'compatibility_view','flow_official_stock_summary',
    'physical_core','flow_official_stock_summary_core_v1',
    'session_metadata','flow_official_stock_summary_session_meta_v1',
    'known_writer_rebound_to_physical_tables',true,
    'no_scoring_or_ranking_change',true
  ),false
FROM flow_official_stock_summary_compaction_stats_v1 s;

DO $do$
DECLARE
  v_before bigint; v_after bigint; v_sessions bigint; v_expected_sessions bigint;
  v_sha_before text; v_sha_after text;
BEGIN
  SELECT before_rows,before_sessions,logical_sha256
    INTO v_before,v_expected_sessions,v_sha_before
  FROM flow_official_stock_summary_compaction_stats_v1;
  SELECT logical_view_rows,session_rows,logical_sha256_after
    INTO v_after,v_sessions,v_sha_after
  FROM public.flow_official_stock_summary_compaction_manifest_v1
  WHERE compaction_contract='OFFICIAL_STOCK_SUMMARY_SESSION_META_V1';
  IF v_before<>v_after OR v_expected_sessions<>v_sessions OR v_sha_before IS DISTINCT FROM v_sha_after THEN
    RAISE EXCEPTION 'official stock summary logical verification failed: rows %/%, sessions %/%, digest %/%',
      v_before,v_after,v_expected_sessions,v_sessions,v_sha_before,v_sha_after;
  END IF;
END
$do$;

-- Storage registry tracks physical residency while preserving historical
-- measurements through the existing ON UPDATE CASCADE registry FK.
DELETE FROM public.flow_storage_dependency_v1 WHERE object_name='flow_official_stock_summary';
UPDATE public.flow_storage_object_registry_v1 SET
  object_name='flow_official_stock_summary_core_v1',
  object_kind='TABLE',
  storage_class='HOT_OPERATIONAL',
  operational_dependency='PHYSICAL_CORE_FOR_FLOW_OFFICIAL_STOCK_SUMMARY_COMPATIBILITY_VIEW',
  research_dependency='CANONICAL_PIT_MARKET_EVIDENCE',
  reproducibility_state='LOSSLESS_CORE_PLUS_SESSION_METADATA_COMPATIBILITY_VIEW',
  retention_requirement='RETAIN_CANONICAL_PIT_SOURCE; DO NOT REMOVE',
  canonical_state='CANONICAL_PIT_EVIDENCE_CORE',
  derivation_state='NOT_DERIVED; LOSSLESS_NORMALIZED_REPRESENTATION',
  reviewed_at=statement_timestamp()
WHERE object_name='flow_official_stock_summary';

SELECT public.flow_refresh_storage_registry_v1();
UPDATE public.flow_storage_object_registry_v1 SET
  storage_class='HOT_OPERATIONAL',
  operational_dependency='SESSION_METADATA_FOR_FLOW_OFFICIAL_STOCK_SUMMARY_COMPATIBILITY_VIEW',
  research_dependency='CANONICAL_PIT_SOURCE_PROVENANCE',
  reproducibility_state='ONE_VERIFIED_METADATA_ROW_PER_TRADE_DATE',
  retention_requirement='RETAIN_WITH_CANONICAL_STOCK_SUMMARY_CORE',
  canonical_state='CANONICAL_PIT_EVIDENCE_SESSION_METADATA',
  derivation_state='LOSSLESS_NORMALIZATION_OF_FORMER_ROW_REPEATED_METADATA',
  reviewed_at=statement_timestamp()
WHERE object_name='flow_official_stock_summary_session_meta_v1';
SELECT public.flow_refresh_storage_date_ranges_v1();
