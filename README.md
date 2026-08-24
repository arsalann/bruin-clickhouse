# Bruin ClickHouse Examples

This repository contains Bruin pipelines that materialize data into ClickHouse.

## Pipelines

- `bruin-clickhouse-101`: a comprehensive Bruin + ClickHouse feature showcase, including SQL, Python, seed, sensor, and ingestr assets.
- `bruin-shop-clickhouse`: a live Shopify pipeline using ingestr source assets (T1), conformed models (T2), and Shopify-only analytical marts (T3).
- `bruin-payments-clickhouse`: near-real-time fintech payments and fraud monitoring. PostgreSQL change capture into an append-only change log, incremental minute rollups with a lookback window, daily KPIs, a serving view, and a Dashboard-as-Code dashboard, on a one-minute schedule.

Run from the repository root:

```bash
bruin validate bruin-clickhouse-101 --config-file .bruin.yml --environment default
bruin run bruin-clickhouse-101/pipeline.yml --config-file .bruin.yml --environment default --exclude-tag requires-postgres-default
bruin validate bruin-shop-clickhouse --config-file .bruin.yml --environment default
bruin run bruin-shop-clickhouse/pipeline.yml --config-file .bruin.yml --environment default
```

The payments pipeline is self-contained: it brings up its own PostgreSQL source and ClickHouse destination in Docker and ships a committed config for them, so it runs end to end with no cloud account.

```bash
docker compose -f bruin-payments-clickhouse/docker/compose.yml up -d
bruin validate bruin-payments-clickhouse --config-file bruin-payments-clickhouse/docker/bruin-local.yml
```

See `bruin-clickhouse-101/README.md` for the feature map, materialization behavior, and the optional PostgreSQL ingestion setup, and `bruin-payments-clickhouse/README.md` for the change-capture and lookback story.
