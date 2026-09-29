# ClickHouse Use Cases & Template Ideas — Research + Brainstorm

Research backing new Bruin-on-ClickHouse showcase templates. Specced so far:

- **A — real-time payments & fraud monitoring** → [`payments-clickhouse-requirements.md`](./payments-clickhouse-requirements.md)
- **F — programmatic adtech analytics** → [`adtech-clickhouse-requirements.md`](./adtech-clickhouse-requirements.md)

---

## 1. Top ClickHouse use cases (2026)

In rough order of how strongly they define ClickHouse:

1. **Real-time / user-facing analytics dashboards** — aggregate huge datasets in ms; column
   store + vectorized execution + incremental materialized views. The flagship pattern.
2. **Observability (logs, metrics, traces)** — fastest-growing; productized as **ClickStack**
   (OTel-native); ~14x compression; replacing Elasticsearch for logging is the common wedge.
3. **Event / clickstream & product analytics** — ClickHouse's origin ("Clickstream + Data
   Warehouse"); funnels, retention, sessionization, conversion.
4. **Time-series / IoT / financial tick data** — sensor telemetry, market data; fast range +
   aggregation, downsampling, ASOF joins.
5. **Vector search / RAG** — embeddings + similarity search for AI apps.

**Sources:** [Use cases](https://clickhouse.com/use-cases) ·
[Real-time analytics](https://clickhouse.com/resources/engineering/what-is-real-time-analytics) ·
[Observability](https://clickhouse.com/docs/use-cases/observability/introduction) ·
[ClickStack](https://clickhouse.com/use-cases/observability) ·
[Product analytics](https://clickhouse.com/blog/building-product-analytics-with-clickhouse) ·
[Time-series](https://clickhouse.com/resources/engineering/what-is-time-series-database) ·
[Industries](https://clickhouse.com/industries)

**Most prominent verticals:** AdTech and Finance/fintech, then IoT, observability, e-commerce,
gaming ([AdTech to Finance](https://www.gocodeo.com/post/clickhouse-use-cases-in-2025-from-ad-tech-to-finance-analytics)).

---

## 2. Repo gap analysis

Existing pipelines cover **Bruin mechanics** (`bruin-clickhouse-101`) and a **batch medallion
build** (`bruin-shop-clickhouse`, Shopify). Missing: anything leaning on ClickHouse's signature
engine features (`AggregatingMergeTree`, materialized views, TTL, codecs, skip/vector indexes,
`windowFunnel`/`retention`) — and no CDC, no observability, no time-series, no vector search.

---

## 3. Template proposals

| # | Template | ClickHouse features it uniquely shows | Bruin mechanics | Repo fit |
|---|----------|----------------------------------------|-----------------|----------|
| **A** | **Real-time analytics rollups** (chosen → payments/fraud) | AggregatingMergeTree, MV, `-State`/`-Merge`, projections | `time_interval`/`merge` incremental, `ddl`, CDC | Fills the #1 use case, absent today |
| **B** | **Observability / ClickStack-lite** (logs+traces+metric rollups) | `Map` attributes, `LowCardinality`, ZSTD/Delta codecs, TTL, bloom_filter skip index | `append`, rollup MVs, anomaly `custom_checks` | #2 use case; huge market pull |
| **C** | **Product analytics** (sessions, funnels, retention) | `windowFunnel()`, `retention()`, `sequenceMatch`, `uniqCombined`, `arrayJoin` | Builds on existing Shopify `t1_events`; new marts | Reuses live data; CH-only SQL |
| **D** | **Time-series / IoT** (downsample cascade 1s→1m→1h) | `DateTime64`, Delta+DoubleDelta codecs, `ASOF JOIN`, `WITH FILL` gap-fill | `time_interval` shines; cascading rollups | #4 use case; strong `time_interval` demo |
| **E** | **Vector search / RAG** (embed docs → similarity) | `Array(Float32)`, `cosineDistance`, HNSW vector index, full-text index | Python asset computing real embeddings | #5 use case; AI-native story |
| **F** | **Programmatic adtech** (log-level delivery + cross-channel spend + attribution) → [spec](./adtech-clickhouse-requirements.md) | `ASOF JOIN`, `windowFunnel`, `uniqCombined`, `quantileTDigest`, codecs, TTL, skip indexes, projections, dictionaries, `SAMPLE BY` | 8+ ingestr sources incl. **Kafka** (S3-vs-stream as a tag switch), `interval_modifiers`, `merge`, `hooks`, `unit-test`, cross-pipeline `uri`, 2 schedules, DAC ×3 | Supersets A+C; adtech is the #1 CH vertical; broadest Bruin surface |

**Cross-cutting theme:** each template is a chance to demo an ingestr source the repo lacks —
S3/GCS, Kafka, REST API, BigQuery/Snowflake (today it's only Shopify + Postgres).

---

## 4. Recommended priority

**A → B → C** (then D, E as stretch):

- **A** — the single most "this is why people pick ClickHouse" pattern; highest signal-to-effort. **In progress.**
- **B** — biggest 2026 market story; shows compression/TTL/codecs nothing else does.
- **C** — cheap (rides on data already ingested); `windowFunnel`/`retention` are CH crowd-pleasers.

---

## 5. Key constraint discovered (applies to all templates)

Bruin's ClickHouse support materializes **tables** (`create+replace`, `append`, `delete+insert`,
`time_interval`, `truncate+insert`, `merge`, `ddl`) and **logical views**. Engine config covers
the MergeTree family (`merge_tree`, `replacing_merge_tree`, `shared_merge_tree`,
`replicated_merge_tree`).

**Not first-class:** native trigger-based `CREATE MATERIALIZED VIEW`, and `AggregatingMergeTree`/
`SummingMergeTree` with `AggregateFunction` state columns. → Templates use Bruin-orchestrated
incremental rollups (Mode 1); native MV/AggregatingMergeTree is a documented advanced variant +
product-feedback item. Bruin **does** support CDC (`postgres+cdc://`, `mysql+cdc://`,
`ps_mysql+cdc://`) and **DAC** (Dashboard-as-Code).

**Sources:** Bruin ClickHouse platform + materialization docs (bruin-data.github.io);
[What is CDC](https://getbruin.com/blog/what-is-cdc-change-data-capture/);
[DAC](https://getbruin.com/docs/dac/).

### 5.1 Additional findings (verified 2026-08-18, for all templates)

- **Late-arrival lookback is a real feature** — `interval_modifiers: { start: -2h, end: 0h }` on an
  asset or pipeline shifts `start_date`/`end_date`. Requires the `--apply-interval-modifiers` run
  flag. Warning from the docs: if the filter window and the delete window disagree, `time_interval`
  creates duplicates. → **Resolves O-2 in the payments doc.**
- **`hooks.pre` / `hooks.post` run arbitrary SQL** around a materialization. This is the escape
  hatch for everything Bruin doesn't model declaratively on ClickHouse: `TTL`, per-column `CODEC`,
  `PARTITION BY`, data-skipping indexes, projections, `SAMPLE BY`, `CREATE DICTIONARY`, and native
  materialized views / `AggregatingMergeTree`. Needs an idempotence spike (`IF NOT EXISTS`).
- **Cross-pipeline dependencies exist** — assets carry a `uri`, and `depends` accepts
  `{ uri: ..., mode: full|symbolic }`. `symbolic` shows lineage without waiting. Enables multi-cadence
  designs (one pipeline per schedule, one warehouse).
- **`bruin unit-test`** runs SQL asset unit tests against the configured connection — the right tool
  for business logic like attribution.
- **ingestr source coverage is much broader than the repo uses** — notably for adtech/marketing:
  Google Ads, Facebook Ads, TikTok Ads, LinkedIn Ads, Reddit Ads, Snapchat Ads, Pinterest, Apple Ads,
  Applovin (+ Max), Adjust, AppsFlyer, Google Analytics, Mixpanel, PostHog, Braze, Klaviyo — plus
  S3/GCS/ADLS, Kafka, Kinesis, RabbitMQ, and **Frankfurter** (FX rates, no auth — useful for any
  multi-currency template).
- **`scd2_by_column` / `scd2_by_time` are not supported on ClickHouse**; `datavault_*` strategies
  exist generally.
