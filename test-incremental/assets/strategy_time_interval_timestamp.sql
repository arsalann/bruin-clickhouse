/* @bruin
name: strategy_time_interval_timestamp
type: clickhouse.sql
materialization:
  type: table
  strategy: time_interval
  incremental_key: event_timestamp
  time_granularity: timestamp
depends:
  - bug_test_seed
columns:
  - name: event_timestamp
    type: timestamp
  - name: row_id
    type: varchar
    primary_key: true
  - name: amount
    type: integer
@bruin */

SELECT
    toDateTime(event_date) AS event_timestamp,
    row_id,
    amount
FROM bug_test_seed
WHERE event_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
