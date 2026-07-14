/* @bruin
name: strategy_check_query
type: clickhouse.sql

depends:
  - strategy_check_seed

materialization:
  type: table
  strategy: time_interval
  incremental_key: updated_at
  time_granularity: timestamp

columns:
  - name: updated_at
    type: timestamp
    description: "UTC timestamp when the strategy value was updated."
  - name: name
    type: varchar
    description: "Name of the strategy being checked."
  - name: value
    type: float
    description: "Numeric value recorded for the strategy."
@bruin */

SELECT
    updated_at,
    name,
    value
FROM strategy_check_seed
WHERE updated_at BETWEEN toDateTime64('{{ start_timestamp }}', 6, 'UTC')
                     AND toDateTime64('{{ end_timestamp }}', 6, 'UTC')
