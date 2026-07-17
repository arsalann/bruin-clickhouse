/* @bruin
name: strategy_truncate_insert
type: clickhouse.sql
materialization:
  type: table
  strategy: truncate+insert
depends:
  - bug_test_seed
columns:
  - name: event_date
    type: date
  - name: row_id
    type: varchar
    primary_key: true
  - name: amount
    type: integer
@bruin */

SELECT
    event_date,
    row_id,
    amount
FROM bug_test_seed
WHERE event_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
