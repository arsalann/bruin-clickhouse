# Bruin ClickHouse Examples

This repository contains Bruin pipelines that materialize data into ClickHouse.

## Pipelines

- `bruin-clickhouse-101`: a small customer/order tutorial pipeline.
- `bruin-shop-clickhouse`: a live Shopify pipeline using ingestr source assets (T1), conformed models (T2), and Shopify-only analytical marts (T3).

Run from the repository root:

```bash
bruin validate bruin-clickhouse-101 --config-file .bruin.yml --environment default
bruin run bruin-clickhouse-101/pipeline.yml --config-file .bruin.yml --environment default
bruin validate bruin-shop-clickhouse --config-file .bruin.yml --environment default
bruin run bruin-shop-clickhouse/pipeline.yml --config-file .bruin.yml --environment default
```
