# Bruin Payments ClickHouse

Near-real-time payments authorization and fraud monitoring, built on the pattern
ClickHouse is best at: an operational PostgreSQL database is the system of record, its
changes are captured into ClickHouse, and Bruin folds them into pre-aggregated serving
tables that a Dashboard-as-Code dashboard reads. The pipeline is scheduled every minute,
so the dashboard trails the source by about a minute.

Everything here runs end to end from a clean checkout against two Docker containers. No
cloud account, no credentials to fill in.

| | |
|---|---|
| Source | PostgreSQL `payments.transactions` (operational OLTP) |
| Destination | ClickHouse `bruin_payments` |
| Cadence | every minute (`schedule: "* * * * *"`) |
| Currency | single-currency USD; money carried as integer minor units |
| Timezone | UTC throughout |
| Fraud labels | supplied by the source and monitored, never modelled |

## How it compares to the other pipelines here

| | `bruin-clickhouse-101` | `bruin-shop-clickhouse` | **this pipeline** |
|---|---|---|---|
| Source | Postgres + seeds | Shopify API | **PostgreSQL OLTP, change capture** |
| Cadence | daily | daily | **every minute** |
| Pattern | feature tour | medallion warehouse | **change log → rollup cascade → serving → dashboard** |
| Consumer | learners | analysts | **operations and risk, live** |
| Vertical | generic | commerce | **fintech payments** |

## Architecture

```text
PostgreSQL · payments.transactions          ← system of record
     ▲                                        (Python seed asset writes demo traffic here,
     │                                         including approved → refunded → chargeback
     │                                         restatements as real UPDATEs)
     │  ingestr, cursor on updated_at, append-only
     ▼
bruin_payments.raw_transaction_changes      ← append-only change log, MergeTree
     │                                        one row per captured version
     │  view: null-conformance + LowCardinality encoding
     ▼
bruin_payments.stg_transaction_changes
     │  argMax(…, updated_at) GROUP BY transaction_id, then bucket on created_at
     │  time_interval + 15m lookback
     ▼
bruin_payments.rollup_txn_1m                ← per-minute pre-aggregate, all measures additive
     │                        ╲
     │  merge, 3h lookback     ╲  merge, 3h lookback
     ▼                          ▼
rollup_txn_1h                  kpi_txn_daily  ← additive measures summed from the minute grain;
                                │                uniques and P95 re-derived from the change log
     ┌──────────────────────────┘
     ▼
bruin_payments.serving_realtime_risk        ← view: today live ∪ sealed history + derived rates
     │
     ▼
dashboards/payments_risk.yml + semantic/payments_risk.yml  →  localhost:8321
```

### The assets

| Asset | Type | Strategy | What it is for |
|---|---|---|---|
| `payments.transactions` | Python | `merge` into PostgreSQL | Generates demo traffic and restatements into the system of record |
| `bruin_payments.raw_transaction_changes` | ingestr | `append` | Captures changed rows into an append-only change log |
| `bruin_payments.stg_transaction_changes` | SQL view | — | Non-null, `LowCardinality`-encoded projection of the change log |
| `bruin_payments.rollup_txn_1m` | SQL | `time_interval` + 15m lookback | Per-minute pre-aggregate; the live dashboard's throughput source |
| `bruin_payments.rollup_txn_1h` | SQL | `merge` + 3h lookback | Coarser grain, summed from the minute grain |
| `bruin_payments.kpi_txn_daily` | SQL | `merge` + 3h lookback | Daily KPIs; where additivity stops being free |
| `bruin_payments.serving_realtime_risk` | SQL view | — | One dashboard-ready object over all history |

## Run it

### 1. Start the source and destination

```bash
docker compose -f bruin-payments-clickhouse/docker/compose.yml up -d
```

PostgreSQL comes up with `wal_level=logical`, `REPLICA IDENTITY FULL` and a publication
on `payments.transactions` — the documented prerequisites for log-based CDC — plus the
table itself. Nothing in the pipeline creates the source table; a payments processor
would already own it.

All commands below pass `--config-file bruin-payments-clickhouse/docker/bruin-local.yml`,
a committed config pointing at those containers. Its credentials are local-only demo
values, not secrets. To run against ClickHouse Cloud instead, use your own `.bruin.yml`
and drop the flag.

> The Bruin CLI writes a `.gitignore` next to any config file it loads, so
> `docker/.gitignore` reappears after every command and lists `bruin-local.yml`. That
> file is tracked deliberately — the repository's root `.gitignore` ignores the generated
> one. If you ever need to re-add the config, `git add -f` it.

### 2. Bootstrap

The first run must be a full refresh. `rollup_txn_1m` uses the `time_interval` strategy,
whose delete statement precedes table creation, so it needs one run that creates its
target first.

```bash
bruin run bruin-payments-clickhouse/pipeline.yml \
  --config-file bruin-payments-clickhouse/docker/bruin-local.yml \
  --full-refresh --apply-interval-modifiers \
  --start-date "2026-08-18 09:00:00" \
  --end-date   "2026-08-18 09:00:59.999999"
```

### 3. Run consecutive minutes

Restatements reference the three preceding windows, so run **consecutive** minutes to see
the lifecycle and the lookback do their work. Windows spaced further apart still run, but
every restatement lands as a late-arriving insert rather than an update.

```bash
for m in $(seq -w 1 25); do
  bruin run bruin-payments-clickhouse/pipeline.yml \
    --config-file bruin-payments-clickhouse/docker/bruin-local.yml \
    --apply-interval-modifiers \
    --start-date "2026-08-18 09:$m:00" \
    --end-date   "2026-08-18 09:$m:59.999999"
done
```

> `--apply-interval-modifiers` is not optional. Without it, Bruin uses the interval as
> given and the `interval_modifiers` on the rollup and KPI assets are ignored **silently**
> — the pipeline still succeeds, and late restatements are simply never folded in.

On a schedule, Bruin Cloud computes the interval and applies the modifiers itself, so a
scheduled run needs no flag.

### 4. Serve the dashboard

```bash
dac serve --dir bruin-payments-clickhouse \
  --config bruin-payments-clickhouse/docker/bruin-local.yml \
  --port 8321 --open
```

Validate the definitions, or execute every widget query without a browser:

```bash
dac validate --dir bruin-payments-clickhouse --config bruin-payments-clickhouse/docker/bruin-local.yml
dac check    --dir bruin-payments-clickhouse --config bruin-payments-clickhouse/docker/bruin-local.yml
```

### 5. Tear down

```bash
docker compose -f bruin-payments-clickhouse/docker/compose.yml down -v
```

## Tuning the demo traffic

`pipeline.yml` exposes four variables, overridable with `--var`:

| Variable | Default | Effect |
|---|---|---|
| `txns_per_minute` | 40 | Authorizations generated per minute of the run window |
| `restatement_rate` | 0.06 | Share of earlier authorizations that get restated |
| `restatement_windows` | 3 | How many windows back restatements reach |
| `max_seed_rows` | 20000 | Hard cap per run, so a wide backfill window stays quick |

```bash
bruin run bruin-payments-clickhouse/pipeline.yml \
  --config-file bruin-payments-clickhouse/docker/bruin-local.yml \
  --apply-interval-modifiers --var txns_per_minute=200
```

Every generated row is a pure function of `(window_start_epoch, row_index)`, so the seed
is idempotent: rerunning a window reproduces byte-identical transactions rather than
inventing new ones.

## The two ideas worth taking away

### 1. Late-arriving restatements, and what a lookback window actually buys

A payment is not immutable. An authorization is approved, then refunded days later, then
charged back. Each transition bumps `updated_at` in PostgreSQL, so the capture picks it up
in a *later* run than the one that first recorded the transaction — but the metric has to
change in the minute the authorization *happened*, not the minute the chargeback arrived.

That is why every rollup buckets on `created_at` and never on `updated_at`, and why
`rollup_txn_1m` declares:

```yaml
interval_modifiers:
  start: -15m
```

Each run reprocesses the previous 15 minutes, so a restatement rewrites the minute it
belongs to. Watch it happen:

```sql
-- a transaction that moved through all three states
SELECT transaction_id, arrayStringConcat(groupArray(status), ' -> ') AS lifecycle
FROM (
    SELECT DISTINCT transaction_id, status, updated_at
    FROM bruin_payments.stg_transaction_changes
    ORDER BY transaction_id, updated_at
)
GROUP BY transaction_id
HAVING count() = 3
LIMIT 1
```

In a verified run, transaction `178704372000014` was authorized at `09:02:35` and charged
back at `09:05:09`. Minute `09:02` had been written three minutes earlier showing
`approved = 1`; after the lookback run it reads `approved = 0, chargebacks = 1`. The
sealed minute was corrected in place.

The lookback is the entire correctness budget, and it is a real trade-off. 15 minutes at
minute grain means a restatement arriving 20 minutes late is **never** reflected. Widen
`interval_modifiers.start` to buy a longer correction window and pay for it in recompute
on every single run.

### 2. Additive and non-additive measures are not the same kind of thing

`rollup_txn_1m` stores only measures that survive being summed: counts, volumes, and a
latency *sum*. `rollup_txn_1h` and the additive half of `kpi_txn_daily` are therefore
plain `sum()` queries over the minute grain — which is the whole reason a rollup cascade
is cheap.

Unique cards and P95 latency do not survive it. From a verified 29-minute run:

| Measure | Rolled up naively | Truth | Error |
|---|---|---|---|
| Unique active cards | 1,043 | 932 | +11.9% |
| P95 auth latency | 397 ms | 121 ms | +228% |

So `kpi_txn_daily` re-reads the change log for exactly those two columns, and
`serving_realtime_risk` returns `NULL` for both on the current day rather than a
plausible wrong number. The dashboard's P95 tile pays the cost in the open, re-deriving
the quantile on every render.

Making them additive requires storing aggregate *state* rather than values —
`uniqState`, `quantileState` on an `AggregatingMergeTree` — which Bruin does not expose
as a first-class strategy today, and which brings a genuinely harder correctness problem
under restatements. That analysis is in
[docs/mode2-aggregating-mergetree.md](docs/mode2-aggregating-mergetree.md).

## Reading the change log correctly

`raw_transaction_changes` is append-only and holds one row per captured version, so
`transaction_id` is **not** unique in it. Always collapse before aggregating:

```sql
SELECT transaction_id, argMax(status, updated_at) AS status
FROM bruin_payments.stg_transaction_changes
WHERE created_at >= now('UTC') - INTERVAL 1 HOUR   -- always bound created_at
GROUP BY transaction_id
```

Bound `created_at`, not `updated_at`: all versions of a transaction share one
`created_at`, so a `created_at` bound keeps every version of the transactions in scope,
whereas an `updated_at` bound would slice a transaction's history in half.

`FINAL` is not an option here. The table is a `MergeTree`, not a `ReplacingMergeTree`,
deliberately — ingestr derives the sorting key from the primary key alone, so a
`ReplacingMergeTree` would deduplicate on `transaction_id` and silently discard genuine
earlier versions.

Replaying a completed interval appends rows the table already holds. Results stay correct
because every consumer collapses by `transaction_id`, but it costs storage:

```sql
SELECT count() - uniqExact((transaction_id, updated_at)) AS duplicate_rows
FROM bruin_payments.raw_transaction_changes
```

A `--full-refresh` over the full history clears them.

## Deviations from the original requirements

Four things in the requirements document turned out not to be buildable as specified. Each
was verified against the running toolchain rather than assumed, and
[docs/ingestion-boundaries.md](docs/ingestion-boundaries.md) has the reproductions.

| Specified | Built | Why |
|---|---|---|
| Log-based CDC (`postgres+cdc://`, batch mode) | Cursor-based capture on `updated_at` | ingestr refuses ClickHouse as a managed-CDC destination: *"destination scheme "clickhouse" cannot safely run managed CDC"*. The same source works into DuckDB. Hard `DELETE`s are consequently not captured. |
| `merge` into a `ReplacingMergeTree`, deduplicated on `transaction_id` | `append` into a `MergeTree`, collapsed with `argMax` at read time | ingestr's ClickHouse merge reported 927 rows loaded and persisted 1. Read-time collapse is also the canonical ClickHouse pattern for mutable sources. |
| `amount numeric(18,2)` | `amount_cents bigint` | Schema evolution fails on every incremental run after the first: *"decimal widening requires precision 40"*. Integer minor units are also how card processors actually store money, so every rollup sum is exact. |
| `--exclude-tag requires-postgres-cdc` runs fully offline | The whole pipeline needs PostgreSQL; Docker makes it local | The seed writes to PostgreSQL as the system of record, so change capture is the only path into ClickHouse. "Offline" here means no cloud, not no database. Live-source assets are tagged `requires-postgres`; the generator is tagged `demo-seed` so `--exclude-tag demo-seed` points the pipeline at a real source. |

One asset was added that the requirements did not call for:
`stg_transaction_changes`. Ingestion infers every column as `Nullable`, and ClickHouse
refuses a nullable sorting key, so the conformance has to happen somewhere. Doing it once
in a view beats repeating `ifNull` in every rollup.

## Governance

Every asset declares an owner, layer and domain tags, grain and freshness metadata, and a
description for every column. Blocking checks cover:

- primary-key nullability and uniqueness on both merge-keyed tables;
- each captured version being internally self-consistent;
- no future minutes, hours, dates or authorizations;
- restatements never predating the authorization they restate;
- status counts partitioning the transaction count, and decline reasons partitioning the
  decline count;
- reconciliation between the change log, the minute grain, the hourly grain and the daily
  grain;
- distinct counts never exceeding the transactions they were computed from;
- every derived rate within `[0, 1]`, and every monetary measure non-negative;
- one row per minute and dimension set, which catches a run interval that did not start on
  a minute boundary.

```bash
bruin run bruin-payments-clickhouse/pipeline.yml \
  --config-file bruin-payments-clickhouse/docker/bruin-local.yml --only checks
```

## Useful queries

```bash
CFG=bruin-payments-clickhouse/docker/bruin-local.yml

# grains reconcile
bruin query --config-file $CFG --connection clickhouse-default --query "
SELECT 'minute' AS grain, sum(txns) FROM bruin_payments.rollup_txn_1m
UNION ALL SELECT 'hour', sum(txns) FROM bruin_payments.rollup_txn_1h
UNION ALL SELECT 'day',  sum(txns) FROM bruin_payments.kpi_txn_daily"

# what the dashboard reads
bruin query --config-file $CFG --connection clickhouse-default --query "
SELECT is_today, sum(txns) AS txns, round(sum(approved)/sum(txns), 4) AS approval_rate,
       sum(approved_volume) AS volume_usd
FROM bruin_payments.serving_realtime_risk GROUP BY is_today"

# lineage
bruin lineage bruin-payments-clickhouse/assets/serving/serving_realtime_risk.sql --full
```
