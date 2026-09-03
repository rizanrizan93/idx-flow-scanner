# IDX Flow Scanner

Current production contract: **v0.4.0**.

IDX Flow Scanner is the flow / accumulation / execution layer in the IDX research stack. Version 0.4 removes broker-direct acquisition and broker-dependent authorization from the active production pipeline.

## Objective

Detect high-quality accumulation and early-markup candidates using independent evidence families:

```
OHLCV / absorption proxy
        +
ZAPI foreign flow
        +
market & sector regime
        +
free-float / ownership structure
        +
explicit corporate actions
        +
SMC / ICT execution
        ↓
research ranking
        ↓
ZAPI Flow Decision
        ↓
Execution Ready
```

The scanner does **not** claim to identify a beneficial owner or proprietary "bandar" identity. Price/volume absorption remains a proxy. Ownership files remain factual ownership evidence. No broker-derived smart-money cost is produced in v0.4.

## Active evidence sources

### 1. OHLCV

The managed 400-ticker universe uses database/cache-first daily OHLCV with integrity gates for:

- minimum bar history;
- OHLC geometry;
- stale observations;
- zero-volume density;
- unchanged-close density;
- split/corporate-action-like discontinuities;
- IDX tradeable price fractions;
- next-session execution price bands.

### 2. ZAPI foreign flow

Primary daily flow evidence:

- `finance:idx/foreign-flow`
- `finance:idx/stock-summary` fallback/slow snapshot

Foreign buy/sell/net remain **share-unit** observations. They are validated for window completeness, freshness, duplicates, unit semantics, and buy/sell/net consistency before scoring.

### 3. ZAPI stock-summary / free float

The stock-summary snapshot contributes:

- listed shares;
- tradable shares;
- derived tradable/free-float percentage;
- 20D volume turnover versus tradable shares;
- 20D foreign net shares versus tradable shares.

A very low free float is treated as a risk/structure condition, not automatically as positive accumulation.

### 4. Ownership / KSEI-style slow evidence

Verified ZAPI ownership index:

- `finance:idx/ownership-files`
- categories: `lima-persen`, `satu-persen`, `klasifikasi`, `tipe`

The acquisition path only accepts HTTPS ownership workbooks whose final source is an IDX/KSEI domain. Stored facts include report/publication dates, holder/category information, shares, ownership percentage, local/foreign classification, source URL and file hash.

Ownership is slow-moving evidence. It is never relabelled as broker identity or coordinated operator activity.

### 5. Explicit corporate actions

Verified ZAPI/IDX feeds:

- `finance:idx/issued-history`
- `finance:idx/additional-listings`
- `finance:idx/rights-offerings`
- `finance:idx/stock-splits`

The scanner keeps explicit event dates/spans and share-count facts. Material dilution near the decision date can hard-block execution. Stock split/reverse-split events trigger normalization caution rather than being mistaken for flow.

Upcoming events are included in the acquisition horizon.

## Market context v0.4

Market context is now sector-aware.

When sector membership is available for the 400-ticker universe:

- market regime: **30%**
- sector regime: **30%**
- sector-relative strength: **25%**
- market-relative strength: **15%**

Sector regime uses 20D/60D breadth and median returns. This prevents a ticker from being judged only against the entire universe when its own sector is weak or strong.

## Active v0.4 scoring priors

These are research priors, not fitted coefficients:

- accumulation / absorption: **24%**
- ZAPI foreign flow: **20%**
- market + sector context: **15%**
- free-float structure: **10%**
- ownership: **8%**
- corporate action: **5%**
- retail exhaustion: **6%**
- price-flow divergence: **4%**
- SMC / ICT execution: **4%**
- risk / liquidity: **4%**

Correlated OHLCV observations are treated as one latent evidence family. Data quality is a confidence haircut, not a separate alpha source.

## Decision lanes

### Raw Research Priority

All valid managed-universe results. PRICE_PROXY rows remain visible for research.

### ZAPI Flow Decision — Top 20

Requires, at minimum:

- `ZAPI_FLOW` evidence tier;
- full, fresh, valid foreign-flow window;
- price quality >= 70;
- distribution risk < 70;
- non-distribution phase/action.

### Execution Ready — Top 10

Adds stricter execution authorization:

- ZAPI coverage >= 80%;
- score >= 65;
- valid SMC/ICT execution geometry;
- valid IDX price fractions and next-session price band;
- acceptable data staleness;
- no extreme-low-free-float guard;
- no material recent/upcoming dilution hard block.

## SMC / ICT execution

The execution overlay retains:

- liquidity sweep;
- CHOCH;
- BOS;
- bullish FVG;
- entry zone;
- invalidation;
- TP1 / TP2;
- structural RR;
- IDX price fraction checks;
- next-session price-band checks.

## Calibration

Current weights and thresholds are **not automatically retuned** from a small sample.

The OOS memory records:

- 5D return;
- 20D return;
- 60D return;
- 20D MFE;
- 20D MAE;
- phase;
- evidence tier;
- signal score.

Calibration tooling reports score buckets, hit rate, payoff distribution, MFE/MAE and monotonicity. Current readiness policy:

- threshold review: at least **200 completed 20D observations**;
- weight review: at least **400 completed 20D** and **150 completed 60D observations**.

Any future weight change should be walk-forward/OOS and include transaction-cost/slippage assumptions. No snapshot-only tuning.

## ZAPI warm job

The scheduled GitHub workflow is ZAPI-only.

It refreshes:

- `zapi_idx_foreign_60d.csv.gz`
- `zapi_idx_foreign_60d.json`
- `zapi_stock_summary_latest.csv.gz`
- `zapi_ownership_latest.csv.gz`
- `zapi_capital_actions.csv.gz`

Ownership is refreshed weekly or when its cache is missing because it is slow-moving. Corporate actions include recent and upcoming periods.

The workflow no longer consumes GOAPI or Index Alpha broker budgets and no longer attempts direct-IDX broker acquisition.

## Broker-direct retirement

v0.4 active runtime:

- does not call GOAPI broker endpoints;
- does not call Index Alpha broker endpoints;
- does not call the retired direct-IDX broker collector;
- does not rank or authorize on broker data;
- does not display `BROKER_PENDING` / `BROKER_VERIFIED`;
- does not calculate or display an estimated bandar price/cost.

Some legacy broker modules/database columns may remain temporarily for backward-compatible tests and historical persisted runs. They are dormant: `app.py`, the active Streamlit pipeline and the ZAPI warm workflow do not invoke them.

Database schema cleanup is intentionally deferred until the dedicated IDX Flow Supabase connection is available for a separate migration/parity audit.

## Supabase

Production persistence is designed for the dedicated **IDX Flow Scanner** project.

No Supabase schema change is part of the v0.4 ZAPI-only code refactor in this branch. When the correct dedicated project is connected, migration parity, RLS, advisors and removal/archival of obsolete broker entities should be audited separately before any schema mutation.

## Deployment

Streamlit Community Cloud:

- repository: `rizanrizan93/idx-flow-scanner`
- branch: `main`
- app file: `app.py`
- backend secrets: `SUPABASE_URL`, `SUPABASE_SECRET_KEY`
- ZAPI acquisition secret: `ZAPI_KEY`

Run locally:

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
streamlit run app.py
```

Tests:

```bash
PYTHONPATH=src pytest -q
```
