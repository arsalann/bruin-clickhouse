/* @bruin
name: bug_test_seed
type: clickhouse.sql
materialization:
  type: table

columns:
  - name: event_date
    type: date
  - name: row_id
    type: varchar
    primary_key: true
  - name: amount
    type: integer
@bruin */

SELECT toDate('2026-07-11') AS event_date, 'row_1' AS row_id, toInt64(10) AS amount
UNION ALL SELECT toDate('2026-07-12'), 'row_2', toInt64(20)
UNION ALL SELECT toDate('2026-07-13'), 'row_3', toInt64(30)
UNION ALL SELECT toDate('2026-07-14'), 'row_4', toInt64(40)
UNION ALL SELECT toDate('2026-07-15'), 'row_5', toInt64(50)
