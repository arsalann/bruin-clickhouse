/* @bruin
name: bruin_shop.t3_customer_cohorts
type: clickhouse.sql
description: "T3 monthly first-order cohorts with retention, order, revenue, and margin measures."
materialization:
  type: table
  strategy: create+replace
depends:
  - bruin_shop.t2_customers
  - bruin_shop.t2_orders

tags:
  - t3
  - mart
domains:
  - commerce
  - marketing
meta:
  grain: one row per cohort month and activity month

custom_checks:
  - name: contains customer cohorts
    description: Ensures customers with successful orders produce cohort rows.
    query: SELECT count() > 0 FROM bruin_shop.t3_customer_cohorts
    value: 1
    blocking: true
  - name: retention is bounded by cohort size
    description: Ensures retained customer counts never exceed original cohort sizes.
    query: |
      SELECT cohort_id
      FROM bruin_shop.t3_customer_cohorts
      WHERE retained_customers > cohort_customers
    count: 0
    blocking: true
  - name: month zero equals cohort size
    description: Ensures every acquired customer appears in the acquisition month.
    query: |
      SELECT cohort_id
      FROM bruin_shop.t3_customer_cohorts
      WHERE months_since_first_order = 0
        AND retained_customers != cohort_customers
    count: 0
    blocking: true

unit_tests:
  - name: measures month-zero retention
    inputs:
      - asset: bruin_shop.t2_customers
        rows:
          - {customer_id: 1, successful_order_count: 1, first_order_date: "2026-01-05"}
      - asset: bruin_shop.t2_orders
        rows:
          - {order_id: 1, customer_id: 1, order_date: "2026-01-05", is_successful_order: 1, net_revenue: 100, contribution_margin: 40}
    expected:
      count: 1
      rows:
        - {months_since_first_order: 0, cohort_customers: 1, retained_customers: 1, successful_orders: 1, net_revenue: 100, retention_rate: 1}

columns:
  - name: cohort_id
    type: String
    description: "Stable identifier of the cohort-month and activity-month grain."
    primary_key: true
    checks:
      - name: not_null
      - name: unique
  - name: cohort_month
    type: Date
    description: "Month of customers' first successfully captured order."
  - name: order_month
    type: Date
    description: "Month containing retained customer activity."
  - name: months_since_first_order
    type: UInt32
    description: "Whole months elapsed since cohort acquisition."
    checks:
      - name: non_negative
  - name: cohort_customers
    type: UInt64
    description: "Customers originally acquired in the cohort month."
  - name: retained_customers
    type: UInt64
    description: "Cohort customers with a successful order in the activity month."
  - name: successful_orders
    type: UInt64
    description: "Successfully captured orders from retained customers."
  - name: net_revenue
    type: Decimal(18, 2)
    description: "Captured revenue net of refunds from retained customers."
    checks:
      - name: non_negative
  - name: contribution_margin
    type: Decimal(18, 2)
    description: "Contribution margin before paid-media spend from retained customers."
  - name: retention_rate
    type: Float64
    description: "Retained customers divided by original cohort customers."
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
            toStartOfMonth(assumeNotNull(first_order_date)) AS cohort_month
        FROM bruin_shop.t2_customers
        WHERE first_order_date IS NOT NULL
    ),
    monthly_orders AS (
        SELECT
            customer_id,
            toStartOfMonth(order_date) AS order_month,
            count() AS successful_orders,
            toDecimal64(sum(net_revenue), 2) AS net_revenue,
            toDecimal64(sum(contribution_margin), 2) AS contribution_margin
        FROM bruin_shop.t2_orders
        WHERE is_successful_order = 1
        GROUP BY customer_id, toStartOfMonth(order_date)
    ),
    cohort_sizes AS (
        SELECT
            cohort_month,
            count() AS cohort_customers
        FROM cohorts
        GROUP BY cohort_month
    )
SELECT
    concat(
        toString(c.cohort_month),
        '_m',
        toString(dateDiff('month', c.cohort_month, m.order_month))
    ) AS cohort_id,
    c.cohort_month AS cohort_month,
    m.order_month AS order_month,
    toUInt32(dateDiff('month', c.cohort_month, m.order_month)) AS months_since_first_order,
    s.cohort_customers AS cohort_customers,
    countDistinct(m.customer_id) AS retained_customers,
    sum(m.successful_orders) AS successful_orders,
    toDecimal64(sum(m.net_revenue), 2) AS net_revenue,
    toDecimal64(sum(m.contribution_margin), 2) AS contribution_margin,
    round(toFloat64(retained_customers) / toFloat64(s.cohort_customers), 4) AS retention_rate
FROM cohorts AS c
INNER JOIN monthly_orders AS m
    ON c.customer_id = m.customer_id
    AND m.order_month >= c.cohort_month
INNER JOIN cohort_sizes AS s
    ON c.cohort_month = s.cohort_month
GROUP BY c.cohort_month, m.order_month, s.cohort_customers
