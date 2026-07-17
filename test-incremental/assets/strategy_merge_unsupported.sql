/* @bruin
name: strategy_merge_unsupported
type: clickhouse.sql
materialization:
  type: table
  strategy: merge
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
    update_on_merge: true
@bruin */

SELECT
    event_date,
    row_id,
    amount
FROM bug_test_seed
WHERE event_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
