/* @bruin
name: raw_orders
type: clickhouse.sql
materialization:
   type: table

columns:
  - name: order_id
    type: integer
    description: "Unique order identifier."
    primary_key: true
    checks:
        - name: not_null
        - name: positive
        - name: non_negative
        - name: unique
  - name: customer_id
    type: integer
    description: "Customer who placed the order."
    checks:
        - name: not_null
        - name: positive
  - name: order_date
    type: date
    description: "Date the order was placed."
    checks:
        - name: not_null
  - name: order_status
    type: varchar
    description: "Current order status."
    checks:
        - name: not_null
  - name: amount
    type: float
    description: "Order amount in USD."
    checks:
        - name: non_negative
@bruin */

SELECT
    1001 AS order_id,
    1 AS customer_id,
    toDate('2024-04-01') AS order_date,
    'paid' AS order_status,
    CAST(129.50 AS Float64) AS amount
UNION ALL
SELECT
    1002 AS order_id,
    2 AS customer_id,
    toDate('2024-04-02') AS order_date,
    'paid' AS order_status,
    CAST(320.00 AS Float64) AS amount
UNION ALL
SELECT
    1003 AS order_id,
    2 AS customer_id,
    toDate('2024-04-05') AS order_date,
    'refunded' AS order_status,
    CAST(45.00 AS Float64) AS amount
UNION ALL
SELECT
    1004 AS order_id,
    3 AS customer_id,
    toDate('2024-04-07') AS order_date,
    'paid' AS order_status,
    CAST(210.25 AS Float64) AS amount
UNION ALL
SELECT
    1005 AS order_id,
    4 AS customer_id,
    toDate('2024-04-09') AS order_date,
    'paid' AS order_status,
    CAST(80.00 AS Float64) AS amount
UNION ALL
SELECT
    1006 AS order_id,
    3 AS customer_id,
    toDate('2024-04-11') AS order_date,
    'paid' AS order_status,
    CAST(90.75 AS Float64) AS amount
UNION ALL
SELECT
    1007 AS order_id,
    5 AS customer_id,
    toDate('2024-04-12') AS order_date,
    'paid' AS order_status,
    CAST(55.50 AS Float64) AS amount
