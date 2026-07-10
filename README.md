# Bruin ClickHouse 101

A simple end-to-end Bruin pipeline that materializes demo customer and order data into ClickHouse.

Run it from the repository root:

```bash
bruin validate bruin-clickhouse-101 --config-file .bruin.yml.sample
bruin run bruin-clickhouse-101/pipeline.yml --config-file .bruin.yml.sample
```
