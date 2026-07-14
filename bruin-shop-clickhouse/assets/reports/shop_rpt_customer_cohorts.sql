/* @bruin
name: shop_rpt_customer_cohorts
type: clickhouse.sql
materialization:
   type: table
depends:
    - shop_stg_customers
    - shop_stg_orders

columns:
  - name: cohort_id
    type: varchar
    primary_key: true
    checks:
        - name: not_null
        - name: unique
  - name: cohort_month
    type: date
  - name: order_month
    type: date
  - name: months_since_first_order
    type: integer
  - name: cohort_customers
    type: integer
  - name: retained_customers
    type: integer
  - name: successful_orders
    type: integer
  - name: net_revenue
    type: float
  - name: retention_rate
    type: float
@bruin */

WITH
    cohorts AS (
        SELECT
            customer_id,
            toStartOfMonth(first_order_date) AS cohort_month
        FROM shop_stg_customers
        WHERE successful_order_count > 0
    ),
    monthly_orders AS (
        SELECT
            customer_id,
            toStartOfMonth(order_date) AS order_month,
            countIf(is_successful_order = 1) AS orders,
            sum(net_revenue) AS net_revenue
        FROM shop_stg_orders
        WHERE is_successful_order = 1
        GROUP BY
            customer_id,
            toStartOfMonth(order_date)
    ),
    cohort_sizes AS (
        SELECT
            cohort_month,
            count() AS cohort_customers
        FROM cohorts
        GROUP BY cohort_month
    )
SELECT
    concat(toString(c.cohort_month), '_m', toString(dateDiff('month', c.cohort_month, m.order_month))) AS cohort_id,
    c.cohort_month AS cohort_month,
    m.order_month AS order_month,
    dateDiff('month', c.cohort_month, m.order_month) AS months_since_first_order,
    s.cohort_customers AS cohort_customers,
    countDistinct(m.customer_id) AS retained_customers,
    sum(m.orders) AS successful_orders,
    round(sum(m.net_revenue), 2) AS net_revenue,
    round(if(s.cohort_customers = 0, 0, retained_customers / s.cohort_customers), 4) AS retention_rate
FROM cohorts AS c
INNER JOIN monthly_orders AS m
    ON c.customer_id = m.customer_id
    AND m.order_month >= c.cohort_month
INNER JOIN cohort_sizes AS s
    ON c.cohort_month = s.cohort_month
GROUP BY
    c.cohort_month,
    m.order_month,
    s.cohort_customers
