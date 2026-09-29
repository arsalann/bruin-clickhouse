# Requirements — Template A: Real-Time Payments & Fraud Monitoring on ClickHouse

| | |
|---|---|
| **Status** | Draft for review |
| **Owner** | Arsalan (arsalan.noorafkan@getbruin.com) |
| **Date** | 2026-08-17 |
| **Industry** | Fintech / digital payments |
| **Use case** | Real-time payments authorization & fraud monitoring dashboard |
| **Source** | PostgreSQL (operational payments OLTP), via **CDC (batch mode)** |
| **Destination** | ClickHouse |
| **Visualization** | Bruin **DAC** (Dashboard-as-Code) |
| **Ingestion cadence** | Batch CDC, pipeline scheduled **every 1 minute** |
| **Demo data** | **Python seed assets** (generated fake transactions) |
| **Target repo** | `bruin-clickhouse` showcase |
| **Proposed pipeline dir** | `bruin-payments-clickhouse/` |
| **Related** | `bruin-clickhouse-101` (mechanics), `bruin-shop-clickhouse` (batch medallion) |

---

## 1. Summary

A showcase pipeline for ClickHouse's flagship use case — **near-real-time, pre-aggregated
serving tables powering an operational dashboard** — grounded in the fintech vertical.

A payments processor's operational **PostgreSQL** database is the system of record for every
card authorization. It cannot absorb heavy analytical scans without risking live-auth latency,
so transaction changes are **captured to ClickHouse via Bruin CDC** — an ingestr asset in
**batch mode, scheduled every minute** — and folded into low-latency rollups by **Bruin's
incremental SQL assets**. **DAC dashboards** visualize the result: authorizations/min, approval
and decline rates, decline-reason mix, fraud-flag rate, and payment volume, by merchant
category, card network, and country. For offline demos, **Python seed assets generate fake
transactions** so the whole pipeline runs with no external database.

The template shows Bruin owning the whole path: **CDC ingestion → incremental SQL rollups →
serving → Dashboard-as-Code**, governed, tested, and scheduled every minute.

---

## 2. Why this industry & use case

The two most prominent ClickHouse verticals are **AdTech** and **Finance/fintech**
([GoCodeo 2025 use cases](https://www.gocodeo.com/post/clickhouse-use-cases-in-2025-from-ad-tech-to-finance-analytics),
[ClickHouse industries](https://clickhouse.com/industries)). We pick **fintech** over AdTech
for three reasons:

1. **Source consistency.** AdTech ingestion is event-stream / Kafka-native; it does not map to
   Postgres CDC. Fintech transactions *are* an OLTP Postgres workload, so CDC is idiomatic.
2. **Canonical reference architecture.** "OLTP Postgres → CDC → ClickHouse → real-time
   dashboard, without slowing down the transactional DB" is a documented ClickHouse pattern
   ([real-time analytics on Postgres](https://clickhouse.com/resources/engineering/real-time-analytics-postgres),
   [Postgres→ClickHouse streaming](https://estuary.dev/blog/postgres-to-clickhouse/)).
3. **Showcase breadth.** Fraud/risk monitoring is a top-cited ClickHouse use case and does not
   overlap the existing commerce pipeline (`bruin-shop-clickhouse`).

**How it complements the existing pipelines:**

| | `bruin-shop-clickhouse` | **`bruin-payments-clickhouse` (this)** |
|---|---|---|
| Source | Shopify API (SaaS) | **PostgreSQL OLTP (CDC)** |
| Cadence | Daily batch | **Every 1 minute** |
| Pattern | Medallion warehouse (t1/t2/t3) | **CDC → rollup → serving → DAC** |
| Consumer | BI / analysts | **Ops / risk live dashboard** |
| Vertical | Commerce | **Fintech / payments** |

---

## 3. Goals / non-goals

### Goals
- Demonstrate **Postgres CDC ingestion** into ClickHouse via an **ingestr YAML asset** in
  **batch mode (every 1 minute)**, handling **transaction state changes** (auth → refund →
  chargeback).
- Demonstrate **Bruin SQL assets** doing fast incremental rollups with minimal recompute.
- Demonstrate **DAC dashboards** visualizing the serving layer (dashboards-as-code).
- Provide **Python seed assets that generate fake transactions** for a fully offline demo.
- Handle **late-arriving / out-of-order CDC data** via an explicit lookback window.
- Teach the **additive vs. non-additive metric** trade-off (counts/volume additive; unique
  cards and P95 latency not).
- Stay **idiomatic to what Bruin supports today**; runnable **end-to-end offline**.

### Non-goals
- Not a per-row streaming engine — freshness is micro-batch at the 1-minute schedule.
- Not multi-currency (single-currency USD demo).
- Not a real fraud model (`is_fraud` is a given label, monitored not computed).
- Mode 2 (native ClickHouse MV / `AggregatingMergeTree`) is documented only, not built (§8).

---

## 4. Source of record: PostgreSQL payments OLTP

The operational database (`payments`) backs live card authorizations. The single fact table
captured via CDC is `transactions`.

```sql
-- Postgres: payments.transactions  (the CDC-captured fact)
CREATE TABLE transactions (
    transaction_id   bigint PRIMARY KEY,
    created_at       timestamptz NOT NULL,          -- authorization time (rollup event time)
    updated_at       timestamptz NOT NULL,          -- CDC version cursor; bumps on status change
    merchant_id      bigint      NOT NULL,
    card_id          bigint      NOT NULL,          -- tokenized card ref (unique-cards metric)
    amount           numeric(18,2) NOT NULL,
    currency         text        NOT NULL DEFAULT 'USD',
    status           text        NOT NULL,          -- approved | declined | refunded | chargeback
    decline_reason   text,                           -- insufficient_funds | do_not_honor | fraud_suspected | expired_card | NULL
    card_network     text        NOT NULL,          -- visa | mastercard | amex | discover
    merchant_category text       NOT NULL,          -- grocery | travel | digital_goods | gaming | ...
    country          text        NOT NULL,          -- ISO-2 country of the transaction
    is_fraud         boolean     NOT NULL DEFAULT false,
    auth_latency_ms  integer     NOT NULL           -- authorization latency (P95 KPI)
);
```

**Why this is a realistic CDC workload:** a transaction is not immutable — `status` moves
`approved → refunded → chargeback` over time, each transition bumping `updated_at`. Each batch
run captures those restatements; the raw ClickHouse table collapses them to latest state.

---

## 5. Architecture

### 5.1 DAG

```
  Postgres · payments.transactions              Python seed assets (offline demo)
        │                                                 │  generate fake transactions
        │  ①  ingestr  postgres+cdc://  (batch mode)      │  (incl. restatements)
        │      pipeline runs every 1 minute               │
        ▼                                                 ▼
  raw_transactions  · ReplacingMergeTree (dedup by updated_at / LSN)    ← CDC landing table
        │
        │  ②  SQL: time_interval + lookback
        ▼
  rollup_txn_1m  ──▶ (optional) rollup_txn_1h                           ← incremental rollup
        │
        │  ③  merge (date + dims)
        ▼
  kpi_txn_daily                                                         ← daily KPIs
        │
        │  ④  view: today-so-far ∪ sealed history + derived rates
        ▼
  serving_realtime_risk                                                 ← serving view
        │
        │  ⑤  read
        ▼
  DAC dashboards (YAML/JSX + semantic layer)  →  localhost:8321         ← dashboards-as-code
```

### 5.2 Layers

- **Source (live)** — `payments.transactions` in Postgres (system of record).
- **Source (demo)** — Python seed assets generating fake transactions into ClickHouse.
- **Ingestion** — `ingestr` CDC **YAML asset** (`postgres+cdc://`, **batch mode**, every 1 min).
- **Raw** — `raw_transactions`, `ReplacingMergeTree`, deduped by `transaction_id` on the
  `updated_at` / CDC LSN version, so status restatements collapse to latest.
- **Rollup** — `rollup_txn_1m`, per-minute pre-aggregation via `time_interval` + lookback.
  Optional `rollup_txn_1h` coarser grain.
- **KPI** — `kpi_txn_daily`, per-day KPIs via `merge`, keyed on `(txn_date, dimensions)`.
- **Serving** — `serving_realtime_risk`, a logical view unioning today-so-far ∪ sealed history.
- **Dashboards** — DAC definitions reading the serving/rollup tables (FR-6).

### 5.3 Dashboard KPIs

| KPI | Additive across grains? | Source of truth |
|---|---|---|
| Authorizations / min (TPS proxy) | ✅ count | rollup_txn_1m |
| Approval rate % | ✅ | rollup / kpi |
| Decline rate % + top decline reasons | ✅ counts | rollup / kpi |
| Fraud-flag rate % | ✅ counts | rollup / kpi |
| Payment volume ($ approved) | ✅ sum | rollup / kpi |
| **Unique active cards / merchants** | ❌ **not additive** | re-aggregate from raw |
| **P95 authorization latency** | ❌ **not additive** | re-aggregate from raw |

Dimensions for every KPI: `merchant_category`, `card_network`, `country`.

---

## 6. Functional requirements

### FR-1 — CDC ingestion (ingestr YAML asset)
- Ingest `payments.transactions` via an `ingestr` asset using `postgres+cdc://` in **batch
  mode**, into `raw_transactions` with `engine: replacing_merge_tree`, dedup key =
  `transaction_id`, version = `updated_at` (or CDC LSN).
- Runs on the **pipeline schedule of every 1 minute** — each run captures changes since the last
  run (no continuous stream, no sensor).
- README documents Postgres prereqs: `wal_level=logical`, publication, replication slot
  ([Bruin CDC](https://getbruin.com/blog/what-is-cdc-change-data-capture/)).
- Live-source asset tagged `requires-postgres-cdc`; `bruin run --exclude-tag
  requires-postgres-cdc` runs offline against the Python seed (FR-2).

### FR-2 — Python seed assets (offline demo data)
- One or more **Bruin Python assets** that generate fake `transactions` for a fully offline demo,
  materializing directly into ClickHouse `raw_transactions` (no Postgres required).
- Realistic distributions: statuses, decline reasons, card networks, merchant categories,
  countries, fraud flags, `auth_latency_ms`, timestamps across the run window.
- Include **restatements** (some `approved` rows later flipped to `refunded`/`chargeback`) so the
  ReplacingMergeTree dedup + lookback logic is exercised.
- Default source when `--exclude-tag requires-postgres-cdc` is used; mirrors the Python-asset
  pattern in `bruin-clickhouse-101/assets/python/`.

### FR-3 — Incremental rollup (SQL assets)
- `rollup_txn_1m` aggregates raw to per-minute grain per dimension set. Strategy `time_interval`,
  `time_granularity: timestamp`, `incremental_key: txn_minute`, engine `replacing_merge_tree`
  keyed on `(txn_minute, merchant_category, card_network, country)`.
- **Late-arrival handling (top correctness requirement):** reprocess a lookback window (e.g.
  last N hours) so late/restated rows folding into sealed minutes are recomputed. Lookback is an
  explicit, documented parameter.
- Metrics: `txns`, `approved`, `declined`, `refunded`, `chargebacks`, `fraud_flagged`, `volume`,
  per-reason decline counts.

### FR-4 — KPI / daily (SQL asset)
- `kpi_txn_daily`, strategy `merge`, keyed on `(txn_date, dimensions)`.
- **Additivity:** counts/sums roll up from the minute grain; **unique cards/merchants and P95
  latency do not** — re-aggregate from `raw_transactions`. Headline lesson; motivates Mode 2 (§8).
- Derived rates (approval %, decline %, fraud %) from additive counts.

### FR-5 — Serving (SQL view)
- `serving_realtime_risk` (logical `view`): today-so-far (minute rollup) ∪ sealed history (daily
  KPI) + derived rates — one dashboard-ready object.

### FR-6 — DAC dashboards
- DAC definitions (YAML/JSX) reading `serving_realtime_risk` (+ `rollup_txn_1m` for the live
  view), served at `localhost:8321`.
- **Semantic layer:** define metrics once (`approval_rate`, `decline_rate`, `fraud_rate`,
  `volume`, `authorizations`), reference from widgets.
- Widgets: time-series (auth/min; approval vs. decline), bar (top decline reasons; volume by
  network), single-stat (fraud rate; P95 latency).
- Interactive filters: date-range picker, `merchant_category` dropdown, `country` multiselect.
- Confirm DAC supports the ClickHouse connection (O-7).

### FR-7 — Quality & governance
- `not_null` / `unique` on rollup keys.
- `custom_checks`: raw↔rollup reconciliation within lookback; no future minutes; `approved +
  declined + refunded + chargeback = txns`; volume ≥ 0; approval rate ∈ [0,1].
- Metadata parity with the shop pipeline: `owner`, `tags` (`layer:*`, `domain:payments`),
  `domains`, `meta` (grain, freshness SLA), column descriptions.

---

## 7. Features showcased

**ClickHouse:** `ReplacingMergeTree` CDC dedup (status restatements); `LowCardinality` /
sorting-key design; multi-grain rollup cascade; additive-vs-non-additive metrics; `DateTime64`
bucketing + conditional aggregates.

**Bruin:** ingestr **Postgres CDC** asset (batch, every 1 min); **Python seed assets**;
`time_interval` incremental with lookback; `merge` upserts; `replacing_merge_tree` engine config;
`view`; `custom_checks` + governance; **DAC** dashboards + semantic layer; tag-gated offline vs. live.

---

## 8. Constraint: Bruin ClickHouse support boundary (must read)

Bruin materializes **tables** (`create+replace`, `append`, `delete+insert`, `time_interval`,
`truncate+insert`, `merge`, `ddl`) and **logical views** (`CREATE OR REPLACE VIEW`). Engine
config via `parameters` covers the MergeTree family (`merge_tree`, `replacing_merge_tree`,
`shared_merge_tree`, `replicated_merge_tree`).

Bruin does **not** currently expose, as first-class strategies: native trigger-based
`CREATE MATERIALIZED VIEW`, or `AggregatingMergeTree`/`SummingMergeTree` with `AggregateFunction`
state columns (`-State`/`-Merge`).

- **Mode 1 (runnable):** Bruin-orchestrated incremental rollups (`time_interval` / `merge`).
  Fully supported, idiomatic, delivers the outcome at the 1-minute cadence.
- **Mode 2 (documented appendix):** native MV + `AggregatingMergeTree` with
  `uniqState`/`quantileState` — exactly what makes **unique cards and P95 latency additive**,
  the two metrics Mode 1 re-aggregates from raw
  ([incremental MV](https://clickhouse.com/docs/materialized-view/incremental-materialized-view),
  [cascading MVs](https://clickhouse.com/docs/guides/developer/cascading-materialized-views)).
- **Product feedback (O-1):** first-class `aggregating_merge_tree` + a `materialized_view`
  strategy would let Bruin own Mode 2 natively.

---

## 9. Proposed asset layout

```
bruin-payments-clickhouse/
├── pipeline.yml                              # schedule: every 1 minute; default_connections
├── README.md                                 # story, Mode 1 vs 2, CDC setup, DAC run steps
├── assets/
│   ├── ingestion/
│   │   ├── transactions_cdc.asset.yml        # ingestr postgres+cdc:// (batch) → raw_transactions  [requires-postgres-cdc]
│   │   └── transactions_seed.py              # Python asset: generate fake transactions (offline demo)
│   ├── rollups/
│   │   ├── rollup_txn_1m.sql                 # time_interval, lookback, ReplacingMergeTree
│   │   └── rollup_txn_1h.sql                 # optional coarser grain
│   ├── kpi/
│   │   └── kpi_txn_daily.sql                 # merge; uniques + P95 re-aggregated from raw
│   └── serving/
│       └── serving_realtime_risk.sql         # view: today-so-far ∪ history + rates
└── dashboards/                               # Bruin DAC
    ├── semantic/                             # metrics + dimensions (approval_rate, fraud_rate, ...)
    └── payments_risk.dashboard.(yml|tsx)     # widgets + filters, reads serving_realtime_risk
```

ClickHouse database/schema: `bruin_payments` (parallels `bruin_shop`).

---

## 10. Representative asset sketch (rollup)

```sql
/* @bruin
name: bruin_payments.rollup_txn_1m
type: clickhouse.sql
description: "Per-minute pre-aggregated payment KPIs; reprocesses a lookback window for late/restated CDC."
materialization:
  type: table
  strategy: time_interval
  incremental_key: txn_minute
  time_granularity: timestamp
parameters:
  engine: replacing_merge_tree
depends: [ bruin_payments.raw_transactions ]
owner: risk-platform@example.com
tags: [ "layer:rollup", "domain:payments", "grain:minute" ]
columns:
  - { name: txn_minute, type: DateTime64(3,'UTC'), primary_key: true }
  - { name: merchant_category, type: LowCardinality(String), primary_key: true }
  - { name: card_network, type: LowCardinality(String), primary_key: true }
  - { name: country, type: LowCardinality(String), primary_key: true }
  - { name: txns, type: UInt64 }
  - { name: approved, type: UInt64 }
  - { name: declined, type: UInt64 }
  - { name: fraud_flagged, type: UInt64 }
  - { name: volume, type: Decimal(18,2) }
custom_checks:
  - { name: no_future_minutes, query: "SELECT count() FROM bruin_payments.rollup_txn_1m WHERE txn_minute > now()", value: 0, blocking: true }
@bruin */
SELECT
    toStartOfMinute(created_at)          AS txn_minute,
    merchant_category, card_network, country,
    count()                              AS txns,
    countIf(status = 'approved')         AS approved,
    countIf(status = 'declined')         AS declined,
    countIf(is_fraud)                    AS fraud_flagged,
    sumIf(amount, status = 'approved')   AS volume
FROM bruin_payments.raw_transactions
WHERE created_at BETWEEN parseDateTime64BestEffort('{{ start_timestamp }}')
                     AND parseDateTime64BestEffort('{{ end_timestamp }}')
GROUP BY txn_minute, merchant_category, card_network, country
```

> `unique_cards` and `p95_latency` are intentionally absent (not additive) — computed in
> `kpi_txn_daily` from raw (Mode 1), or via `uniqState`/`quantileState` in Mode 2.

---

## 11. Milestones

1. **M1 — Offline skeleton:** Python seed → `raw_transactions` → `rollup_txn_1m` → serving view;
   runnable with `--exclude-tag requires-postgres-cdc`.
2. **M2 — KPI + cascade:** `kpi_txn_daily` (uniques + P95 from raw) + optional `rollup_txn_1h`.
3. **M3 — CDC ingestion:** real `postgres+cdc://` batch asset (1-min schedule) + Postgres setup guide.
4. **M4 — DAC dashboards:** semantic layer + payments-risk dashboard + filters.
5. **M5 — Governance:** checks, metadata, README polish.
6. **M6 — Advanced appendix:** Mode 2 (`uniqState`/`quantileState`) + Bruin feature-request note.

---

## 12. Acceptance criteria

- `bruin validate` passes.
- `bruin run --exclude-tag requires-postgres-cdc` completes offline (Python seed) and populates
  `serving_realtime_risk`.
- Rollup re-runs are **idempotent** (reconciliation check passes).
- A restated demo transaction (`approved` → `chargeback`) is reflected after a lookback run.
- DAC dashboard renders at `localhost:8321` against ClickHouse.
- README explains Mode 1 vs Mode 2 and the additive-vs-non-additive trade-off.

---

## 13. Risks & open questions

| ID | Item | Notes |
|---|---|---|
| **O-1** | Native MV / `AggregatingMergeTree` not first-class in Bruin | Mode 2 doc-only; product feedback. Check for a raw-DDL escape hatch. |
| **O-2** | Exact `time_interval` lookback mechanism | How Bruin widens the window (run flag vs. config) for late/restated CDC. Verify via docs/MCP. |
| **O-3** | CDC demo reachability | Offline Python seed mandatory (FR-2). Note ClickHouse Cloud IP-allowlist limit — use `clickhouse local`. |
| **O-4** | Cadence vs. "real-time" | Freshness = 1-minute schedule, not sub-second. Frame as "near-real-time." |
| **O-5** | `ReplacingMergeTree` read-time dedup | Serving may need `FINAL` / argMax-by-version; document cost + query pattern. |
| **O-6** | Fraud labels given, not modeled | `is_fraud` from source; template monitors, does not detect. |
| **O-7** | DAC ↔ ClickHouse connection | Confirm DAC supports ClickHouse (docs list Postgres/MySQL/Snowflake/BQ/Redshift/Databricks "+ more via Bruin"). |
| **O-8** | Batch-mode CDC on a 1-min schedule | Confirm ingestr `postgres+cdc://` supports polled/batch drains of the replication slot per run (vs. a continuous stream). |

---

## 14. References

- ClickHouse — [Use cases](https://clickhouse.com/use-cases), [Industries](https://clickhouse.com/industries),
  [Real-time analytics on Postgres](https://clickhouse.com/resources/engineering/real-time-analytics-postgres),
  [Incremental MV](https://clickhouse.com/docs/materialized-view/incremental-materialized-view),
  [Cascading MVs](https://clickhouse.com/docs/guides/developer/cascading-materialized-views)
- Fintech — [ClickHouse use cases: AdTech to Finance](https://www.gocodeo.com/post/clickhouse-use-cases-in-2025-from-ad-tech-to-finance-analytics)
- CDC — [Postgres→ClickHouse streaming](https://estuary.dev/blog/postgres-to-clickhouse/),
  Bruin [What is CDC](https://getbruin.com/blog/what-is-cdc-change-data-capture/), [CDC streaming](https://getbruin.com/blog/what-is-cdc-streaming/)
- DAC — [Overview](https://getbruin.com/docs/dac/), [Academy](https://getbruin.com/learn/bruin-dac/), [repo](https://github.com/bruin-data/dac)
- Repo — `bruin-clickhouse-101`, `bruin-shop-clickhouse`
```
