# IDX Flow Scanner

Current production contract: **v0.3.26**.

Third scanner in the IDX research stack. It is a **clean-room implementation** of public bandarmology / market-operator concepts and is not affiliated with, endorsed by, or a copy of any proprietary Creative Trader / MM Detector formula.

## Objective

Find transitions in stock ownership/flow before or during markup:

`broker accumulation → supply concentration → estimated operator cost → phase detection → SMC/ICT execution → distribution warning`

The scanner is deliberately evidence-aware. A price/volume proxy is **never** labeled as direct broker evidence.

## Current engines

- Direct broker-summary normalization and coverage measurement.
- 5D/20D/60D net-flow windows.
- Accumulation persistence and top-broker concentration.
- Transparent estimated smart-money cost from positive net-volume of top accumulating brokers.
- Reversal-based distribution-risk warning.
- Retail-exhaustion / price-flow divergence features.
- SMC/ICT execution overlay: liquidity sweep, CHOCH proxy, BOS proxy, bullish FVG, entry/invalidation/TP plan.
- Real-money guardrail that blocks insufficient direct evidence.
- Streamlit UI with Silent Accumulation, Distribution Warning, and Single Ticker Audit views.
- Supabase-ready private persistence contract.

## Evidence hierarchy

1. `BROKER_DIRECT`: direct broker-summary observations with enough date coverage.
2. `PRICE_PROXY`: OHLCV-derived research proxy only. This state is automatically `RESEARCH_ONLY` / `GUARDED`.

This hierarchy prevents false coverage and false precision.

## Broker CSV contract

Use `data/templates/broker_summary_template.csv` with columns:

`ticker, trade_date, broker_code, buy_value, sell_value, buy_volume, sell_volume, buy_avg, sell_avg, market_type, source`

Values should reflect a lawful source/export. Do not ingest copied proprietary MM Detector outputs or bypass a data provider's access controls.

## Run locally

```bash
python -m venv .venv
source .venv/bin/activate  # Windows: .venv\\Scripts\\activate
pip install -r requirements.txt
streamlit run app.py
```

For tests:

```bash
PYTHONPATH=src pytest -q
```

## Supabase

Production persistence uses the dedicated Supabase project **`IDX Flow Scanner`**, created in a separate Supabase account and connected directly to this GitHub repository.

The project ref and backend secret are intentionally **not committed to GitHub**. Database schema is versioned under `supabase/migrations/`, with `001_initial_schema.sql` as the current bootstrap migration.

In the Supabase GitHub integration:

- repository: `rizanrizan93/idx-flow-scanner`
- production branch: `main`
- working directory: `.`
- `Deploy to production`: enabled for automatic migration deployment

Runtime should use backend-only secrets:

```toml
SUPABASE_URL = "https://<idx-flow-project-ref>.supabase.co"
SUPABASE_SECRET_KEY = "<backend secret/service-role key>"
```

All scanner tables enable RLS. `anon` and `authenticated` table privileges are revoked; Streamlit persistence is server-side through a secret/service-role key. Never commit a Supabase secret/service-role key to GitHub.

The legacy Emir Supabase project is no longer a Flow Scanner target. `Idx emir framework v2` remains independent for the Emir Scanner, and the Super Scanner database is not part of Flow production persistence.

## Deployment

Designed for Streamlit Community Cloud:

- repository: this repo
- branch: `main`
- app file: `app.py`
- secrets: `SUPABASE_URL`, `SUPABASE_SECRET_KEY`

## Scoring policy

The first pass is strictly PRICE_PROXY + verified foreign evidence. Broker evidence is finalist-only. PRICE_PROXY scoring collapses correlated OHLCV observations before combining them with external evidence. The configured direct-evidence weights remain subject to walk-forward/OOS calibration:

- accumulation 25%
- operator dominance 15%
- cost-basis advantage 10%
- retail exhaustion 10%
- foreign institutional 10% (direct IDX when available; otherwise audited Zapi IDX-derived share flow; neutral only when verified flow is unavailable)
- supply concentration 8%
- price-flow divergence 7%
- market/sector regime 5% (neutral 50 until verified provider is wired)
- SMC/ICT execution 5%
- risk/liquidity 5%

Weights are explicitly **not** claimed to reproduce any proprietary formula. Before real-money use, thresholds and weights must be walk-forward calibrated on historical direct broker data, with out-of-sample evaluation and transaction-cost/slippage assumptions.

## Free-tier stock-level broker evidence

- Index Alpha is an optional Bearer-token provider for stock-level broker summary; plan/quota failure is treated as provider unavailability, never as evidence.
- Broker enrichment occurs only after the guarded Top-5 has been selected, so stronger direct evidence cannot remove a ticker from the proxy shortlist.
- The free policy is pinned to five tickers and at most five exact-day requests per day.
- Production requests always use `from == to`; a multi-day aggregate is never expanded into synthetic daily rows.
- Cached rows carry `INDEX_ALPHA_BROKER_SUMMARY`, verified vendor provenance, and regular-market (`RG`) scope.
- The existing gate still requires at least 10 broker days, 70% 20D coverage, six brokers, <=10% buy/sell balance error, and >=95% verified provenance before `BROKER_DIRECT`.
- Without `INDEX_ALPHA_KEY`, the provider is a no-op and scanner behavior stays PRICE_PROXY/GUARDED.

## v0.2.5 foreign evidence

- Bundled Zapi IDX-derived foreign-flow cache covers the managed 400-ticker universe for 20 trading days.
- Zapi rows persist in `flow_vendor_foreign_flows`, never in the direct-IDX `flow_official_stock_flows` table.
- Foreign buy/sell/net remain share-unit evidence and are never promoted to broker-direct evidence or bandar cost.
- Direct IDX HTTP remains preferred on equal coverage, but cloud 403/Cloudflare failures fail closed.
- GOAPI is optional; the scanner remains fully operational in PRICE_PROXY/GUARDED mode when stock-level broker evidence is absent.

## Production integrity gates

- `COMPLETED` means full requested-universe completion; `COMPLETED_PARTIAL` is explicit for >=90% but <100%.
- Price cache/seed frames older than seven calendar days are rejected before they can define the cross-sectional reference date.
- Zero-volume density above 20% over 20D or 35% over 60D blocks guarded broker-budget promotion and direct authorization.
- The OHLCV seed refresh is scheduled on weekdays and replaces the tracked seed only after the integrity gate passes.
- `idx_400_syariah.csv` is a current snapshot, not point-in-time historical membership evidence.

## Next production gates

- Verify the dedicated `IDX Flow Scanner` project has applied all pending migrations.
- Verify RLS, backend service-role grants, and Supabase Security/Performance Advisor findings.
- Configure Streamlit `SUPABASE_URL` and `SUPABASE_SECRET_KEY` for the dedicated project.
- Verified broker-summary ingestion adapter and freshness audit.
- Persistent OHLCV/broker caches and resumable 400-ticker jobs.
- Independent historical labels for accumulation → markup and distribution → drawdown.
- Walk-forward/OOS calibration; no snapshot-only tuning.
- Session/EOD data lineage and source quorum.

## v0.1.1 proxy integrity

When direct broker summary is unavailable, the scanner computes explicitly-labelled OHLCV accumulation/absorption proxies so research ranking remains informative. These proxies never change `PRICE_PROXY` evidence to `BROKER_DIRECT` and can never pass the real-money guardrail by themselves.
