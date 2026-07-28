# Bruin + ClickHouse feature showcase

This pipeline is a compact tour of Bruin on ClickHouse. It combines SQL transformations, a Python materialization, versioned seed data, a PostgreSQL source and sensor, ingestr replication, lineage, governance metadata, quality checks, and a SQL unit test.

The deterministic core runs against the endpoint configured as **clickhouse-default**. The PostgreSQL branch uses **postgres-default** and is tagged **requires-postgres-default**.

## Pipeline at a glance

~~~text
Optional PostgreSQL branch

pg.source -> pg.sensor.query -> ingestr -> ClickHouse view

Deterministic ClickHouse core

SQL raw assets + seed + Python asset
  -> time_interval staging model
  -> delete+insert customer mart
  -> country revenue table and view
  -> operational snapshot
~~~

## Project layout

~~~text
assets/
├── materialization_types/  SQL examples for create+replace, time_interval,
│                           delete+insert, append, truncate+insert, and view
├── data_definitions/       CSV seed and explicit DDL definition
├── python/                 Python materialization
└── ingestion/              PostgreSQL source, sensor, ingestr, and monitor
~~~

## Asset types and features

| Area | Example assets | Features demonstrated |
| --- | --- | --- |
| SQL materializations | materialization_types/raw_customers.sql, materialization_types/daily_order_snapshot.sql, materialization_types/country_revenue.sql | Table and view materialization; create+replace, time_interval, delete+insert, append, and truncate+insert strategies. |
| Python and seed | python/customer_regions.py, data_definitions/country_targets.asset.yml | A Python function that returns rows and version-controlled CSV reference data with an enforced schema. |
| Source and sensor | ingestion/postgres_orders_source.asset.yml, ingestion/postgres_orders_sensor.asset.yml | An external source definition and a readiness gate before ingestion. |
| Ingestr | ingestion/raw_postgres_orders.asset.yml | Incremental PostgreSQL-to-ClickHouse replication using merge and an explicit high-water mark. |
| DDL and physical layout | data_definitions/order_events_contract.sql | Explicit ClickHouse DDL with a partition key and composite ClickHouse sorting key. |
| Governance | Most assets | Owners, tags, domains, metadata, column descriptions, and classification labels. |
| Quality and testing | materialization_types/country_revenue.sql, materialization_types/customer_order_summary.sql | Built-in and custom quality checks, plus a mocked SQL unit test. |
| Lineage | All dependent assets | Execution ordering and upstream/downstream inspection through bruin lineage. |

## Connections

### ClickHouse Cloud

Keep your existing **.bruin.yml** and configure **clickhouse-default** for the intended Cloud service and database. The run commands work unchanged. Choose the appropriate Bruin environment and do not run a full refresh against production by default.

### Optional PostgreSQL branch

Configure **postgres-default** before running the external-source path. Its source definition, sensor condition, and ingestion mapping live with the implementation in assets/ingestion/.

## Run the pipeline

The examples use **.bruin.yml**. Substitute another target configuration with `--config-file` when needed.

Validate the showcase:

~~~bash
bruin validate bruin-clickhouse-101 \
  --fast \
  --config-file .bruin.yml
~~~

Run the complete showcase when both connections are configured. A full refresh rebuilds destination tables, so use an explicitly intended non-production environment:

~~~bash
bruin run bruin-clickhouse-101/pipeline.yml \
  --config-file .bruin.yml \
  --environment default \
  --full-refresh \
  --start-date 2024-04-01 \
  --end-date 2024-04-15
~~~

If PostgreSQL is not available, bootstrap only the deterministic ClickHouse core:

~~~bash
bruin run bruin-clickhouse-101/pipeline.yml \
  --config-file .bruin.yml \
  --environment default \
  --exclude-tag requires-postgres-default \
  --full-refresh \
  --start-date 2024-04-01 \
  --end-date 2024-04-15
~~~

Run a normal incremental window and its downstream models:

~~~bash
bruin run bruin-clickhouse-101/assets/materialization_types/daily_order_snapshot.sql \
  --downstream \
  --config-file .bruin.yml \
  --environment default \
  --start-date 2024-04-16 \
  --end-date 2024-04-30
~~~

Run data-quality checks without rebuilding the model:

~~~bash
bruin run bruin-clickhouse-101/assets/materialization_types/country_revenue.sql \
  --only checks \
  --config-file .bruin.yml \
  --environment default
~~~

Run the SQL unit test:

~~~bash
bruin unit-test bruin-clickhouse-101/assets/materialization_types/country_revenue.sql \
  --environment default
~~~

The unit-test command resolves its connection from `.bruin.yml` and does not accept `--config-file`.

Inspect the deterministic-core and PostgreSQL lineage branches:

~~~bash
bruin lineage bruin-clickhouse-101/assets/materialization_types/country_revenue.sql --full
bruin lineage bruin-clickhouse-101/assets/ingestion/postgres_order_daily_monitor.sql --full
~~~
