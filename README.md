# Bruin ClickHouse Examples

This repository contains Bruin pipelines that materialize demo data into ClickHouse.

## Pipelines

- `bruin-clickhouse-101`: a small customer/order tutorial pipeline.
- `bruin-shop-clickhouse`: a production-style Shopify analytics showcase with synthetic source contracts (T1), conformed models (T2), and analytical marts (T3).

Run from the repository root:

```bash
bruin validate bruin-clickhouse-101 --config-file .bruin.yml --environment default
bruin run bruin-clickhouse-101/pipeline.yml --config-file .bruin.yml --environment default
bruin validate bruin-shop-clickhouse --config-file .bruin.yml --environment default
bruin run bruin-shop-clickhouse/pipeline.yml --config-file .bruin.yml --environment default
```
