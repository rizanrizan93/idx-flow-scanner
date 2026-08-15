# IDX Flow Scanner

Third scanner in the IDX research stack. It is a **clean-room implementation** of public bandarmology / market-operator concepts and is not affiliated with, endorsed by, or a copy of any proprietary Creative Trader / MM Detector formula.

## Objective

Find transitions in stock ownership/flow before or during markup:

`broker accumulation → supply concentration → estimated operator cost → phase detection → SMC/ICT execution → distribution warning`

The scanner is deliberately evidence-aware. A price/volume proxy is **never** labeled as direct broker evidence.

## v0.1.1 engines

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

The designated production database is the existing Supabase project **`Idx emir framework`** (the first/legacy Emir project), project ref **`utgrknbmtmhpjurvcabg`**. The current Emir Scanner remains on **`Idx emir framework v2`** and is not modified by this scanner.

Apply `supabase/migrations/001_initial_schema.sql` to the designated Flow project. Runtime should use backend-only secrets:

```toml
SUPABASE_URL = "https://utgrknbmtmhpjurvcabg.supabase.co"
SUPABASE_SECRET_KEY = "<backend secret/service-role key>"
```

All scanner tables enable RLS, and `anon` / `authenticated` table privileges are revoked. Streamlit performs server-side persistence only. Never commit the secret/service-role key to GitHub.

A temporary `flow_*` namespace may exist in the Super Scanner database only as a fail-safe while the legacy Emir project's PostgreSQL recovery completes. It must be removed after the designated project passes SQL, migration, and persistence validation.

## Deployment

Designed for Streamlit Community Cloud:

- repository: this repo
- branch: `main`
- app file: `app.py`
- secrets: `SUPABASE_URL`, `SUPABASE_SECRET_KEY`

## Scoring policy

Initial research weights (subject to walk-forward/OOS calibration):

- accumulation 25%
- operator dominance 15%
- cost-basis advantage 10%
- retail exhaustion 10%
- foreign institutional 10% (neutral 50 until a verified provider is wired)
- supply concentration 8%
- price-flow divergence 7%
- market/sector regime 5% (neutral 50 until verified provider is wired)
- SMC/ICT execution 5%
- risk/liquidity 5%

Weights are explicitly **not** claimed to reproduce any proprietary formula. Before real-money use, thresholds and weights must be walk-forward calibrated on historical direct broker data, with out-of-sample evaluation and transaction-cost/slippage assumptions.

## Next production gates

- Designated Supabase project SQL health + clean Flow migration + advisor checks.
- Verified broker-summary ingestion adapter and freshness audit.
- Persistent OHLCV/broker caches and resumable 400-ticker jobs.
- Independent historical labels for accumulation → markup and distribution → drawdown.
- Walk-forward/OOS calibration; no snapshot-only tuning.
- Session/EOD data lineage and source quorum.

## v0.1.1 proxy integrity
When direct broker summary is unavailable, the scanner now computes explicitly-labelled OHLCV accumulation/absorption proxies so research ranking remains informative. These proxies never change `PRICE_PROXY` evidence to `BROKER_DIRECT` and can never pass the real-money guardrail by themselves.
