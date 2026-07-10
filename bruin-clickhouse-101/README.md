# Bruin ClickHouse 101

This is a small end-to-end Bruin pipeline for ClickHouse. It creates two raw demo tables, joins them into a customer-level summary, and publishes a country-level revenue mart.

## Pipeline Graph

- `raw_customers`: static customer dimension data.
- `raw_orders`: static order fact data.
- `customer_order_summary`: joins customers to orders and calculates customer revenue metrics.
- `country_revenue`: aggregates the customer summary into a final country revenue mart.

## Setup

You need a ClickHouse server and a Bruin `clickhouse-default` connection. You can run ClickHouse locally with Docker:

```bash
docker run -d \
  --name bruin-clickhouse-101 \
  -e CLICKHOUSE_DB=default \
  -e CLICKHOUSE_USER=username \
  -e CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1 \
  -e CLICKHOUSE_PASSWORD=password \
  -p 18123:8123 \
  -p 19000:9000 \
  --ulimit nofile=262144:262144 \
  clickhouse/clickhouse-server
```

The repository includes `.bruin.yml.sample` with a matching local connection. You can copy it to `.bruin.yml`, or use it directly with `--config-file .bruin.yml.sample`.

```yaml
default_environment: default
environments:
    default:
        connections:
            clickhouse:
                - name: clickhouse-default
                  username: username
                  password: password
                  host: 127.0.0.1
                  port: 19000
                  database: default
```

## Running the Pipeline

Validate the pipeline:

```bash
bruin validate bruin-clickhouse-101 --config-file .bruin.yml.sample
```

Render the final mart SQL:

```bash
bruin render bruin-clickhouse-101/assets/country_revenue.sql --config-file .bruin.yml.sample
```

Run the full pipeline:

```bash
bruin run bruin-clickhouse-101/pipeline.yml --config-file .bruin.yml.sample
```

Query the final table:

```bash
bruin query \
  --config-file .bruin.yml.sample \
  --connection clickhouse-default \
  --query "select * from country_revenue order by total_paid_amount desc" \
  --limit 10
```
