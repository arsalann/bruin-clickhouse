/* @bruin
name: bruin_shop.t3_customer_cohorts
type: clickhouse.sql
description: "T3 monthly customer cohort retention and revenue mart."
materialization:
   type: table
   strategy: truncate+insert
depends:
    - bruin_shop.t2_customers
    - bruin_shop.t2_orders

custom_checks:
  - name: contains rows
    description: Ensures the materialized table is not empty.
    query: SELECT count() > 0 FROM bruin_shop.t3_customer_cohorts
    value: 1
    blocking: true
  - name: retained customers do not exceed cohort size
    description: Ensures retained customer counts are never larger than the cohort.
    query: |
      SELECT cohort_id, order_month
      FROM bruin_shop.t3_customer_cohorts
      WHERE retained_customers > cohort_customers
    count: 0
    blocking: true
columns:
  - name: cohort_id
    type: varchar
    description: "Identifier for the customer cohort."
    primary_key: true
    checks:
        - name: not_null
        - name: unique
  - name: cohort_month
    type: date
    description: "Month in which customers entered the cohort."
  - name: order_month
    type: date
    description: "Month containing the order date."
  - name: months_since_first_order
    type: integer
    description: "Number of months elapsed since the cohort\u2019s first order month."
  - name: cohort_customers
    type: integer
    description: "Number of customers in the acquisition cohort."
    checks:
      - name: non_negative
  - name: retained_customers
    type: integer
    description: "Cohort customers with a successful order in the activity month."
    checks:
      - name: non_negative
  - name: successful_orders
    type: integer
    description: "Number of successfully paid orders."
    checks:
      - name: non_negative
  - name: net_revenue
    type: float
    description: "Revenue after discounts, refunds, and applicable adjustments."
    checks:
      - name: non_negative
  - name: retention_rate
    type: float
    description: "Retained customers divided by total cohort customers."
    checks:
      - name: min
        value: 0
      - name: max
        value: 1
@bruin */

WITH
    cohorts AS (
        SELECT
            customer_id,
            toStartOfMonth(first_order_date) AS cohort_month
        FROM bruin_shop.t2_customers
        WHERE successful_order_count > 0
    ),
    monthly_orders AS (
        SELECT
            customer_id,
            toStartOfMonth(order_date) AS order_month,
            countIf(is_successful_order = 1) AS orders,
            sum(net_revenue) AS net_revenue
        FROM bruin_shop.t2_orders
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
