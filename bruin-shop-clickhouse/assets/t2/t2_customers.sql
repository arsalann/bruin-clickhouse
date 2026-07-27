/* @bruin
name: bruin_shop.t2_customers
type: clickhouse.sql
description: "Conformed T2 customer dimension with acquisition, lifecycle, and lifetime-value measures."
materialization:
  type: table
  strategy: create+replace
depends:
  - bruin_shop.t1_customers
  - bruin_shop.t2_orders

tags:
  - t2
  - conformed
domains:
  - commerce
  - marketing
meta:
  grain: one row per customer
  source_system: conformed_shopify

custom_checks:
  - name: preserves the customer population
    description: Ensures every source customer appears exactly once.
    query: |
      SELECT
        (SELECT count() FROM bruin_shop.t2_customers)
        =
        (SELECT count() FROM bruin_shop.t1_customers)
    value: 1
    blocking: true
  - name: first order follows signup
    description: Ensures customer lifecycle dates never predate signup.
    query: |
      SELECT customer_id
      FROM bruin_shop.t2_customers
      WHERE first_order_date IS NOT NULL
        AND first_order_date < signup_date
    count: 0
    blocking: true

unit_tests:
  - name: attributes first order and lifecycle
    inputs:
      - asset: bruin_shop.t1_customers
        rows:
          - {customer_id: 10, customer_email: "buyer@example.test", customer_name: "Demo Buyer", market_id: "NY-new-york", state: "NY", city: "New York", signup_channel: "organic", signup_date: "2026-01-01"}
      - asset: bruin_shop.t2_orders
        rows:
          - {order_id: 1, customer_id: 10, order_date: "2026-01-05", order_datetime: "2026-01-05 10:00:00", channel: "paid_search", is_successful_order: 1, net_revenue: 80, contribution_margin: 25}
    expected:
      count: 1
      rows:
        - {customer_id: 10, acquisition_channel: "paid_search", successful_order_count: 1, order_attempt_count: 1, lifetime_net_revenue: 80, lifetime_contribution_margin: 25, days_to_first_order: 4, lifecycle_segment: "first_time"}

columns:
  - name: customer_id
    type: UInt64
    description: "Stable identifier of the customer."
    primary_key: true
    checks:
      - name: not_null
      - name: unique
  - name: customer_email
    type: String
    description: "Synthetic customer email address."
    checks:
      - name: unique
  - name: customer_name
    type: LowCardinality(String)
    description: "Display name of the customer."
  - name: market_id
    type: String
    description: "Stable identifier of the customer's market."
  - name: state
    type: LowCardinality(String)
    description: "Two-letter US state code."
  - name: city
    type: LowCardinality(String)
    description: "City represented by the market."
  - name: signup_channel
    type: LowCardinality(String)
    description: "Channel recorded on the customer profile at signup."
  - name: acquisition_channel
    type: Nullable(String)
    description: "Channel of the first successfully captured order, or null for prospects."
  - name: signup_date
    type: Date
    description: "Date on which the customer signed up."
  - name: successful_order_count
    type: UInt64
    description: "Number of successfully captured order attempts."
    checks:
      - name: non_negative
  - name: order_attempt_count
    type: UInt64
    description: "Number of all order attempts."
    checks:
      - name: non_negative
  - name: lifetime_net_revenue
    type: Decimal(18, 2)
    description: "Captured order revenue net of refunds."
    checks:
      - name: non_negative
  - name: lifetime_contribution_margin
    type: Decimal(18, 2)
    description: "Lifetime contribution margin before paid-media spend."
  - name: first_order_date
    type: Nullable(Date)
    description: "Date of the first successfully captured order."
  - name: latest_order_date
    type: Nullable(Date)
    description: "Date of the latest successfully captured order."
  - name: days_to_first_order
    type: Nullable(Int32)
    description: "Days from signup to the first successfully captured order."
    checks:
      - name: non_negative
  - name: lifecycle_segment
    type: LowCardinality(String)
    description: "Behavioral segment based on successfully captured orders and lifetime revenue."
    checks:
      - name: accepted_values
        value: ["first_time", "loyal", "prospect", "repeat", "vip"]
@bruin */

WITH order_metrics AS (
    SELECT
        customer_id,
        countIf(is_successful_order = 1) AS successful_order_count,
        count() AS order_attempt_count,
        toDecimal64(sum(net_revenue), 2) AS lifetime_net_revenue,
        toDecimal64(sum(contribution_margin), 2) AS lifetime_contribution_margin,
        nullIf(minIf(order_date, is_successful_order = 1), toDate(0)) AS first_order_date,
        nullIf(maxIf(order_date, is_successful_order = 1), toDate(0)) AS latest_order_date,
        nullIf(argMinIf(channel, order_datetime, is_successful_order = 1), '') AS acquisition_channel
    FROM bruin_shop.t2_orders
    GROUP BY customer_id
)
SELECT
    c.customer_id AS customer_id,
    c.customer_email AS customer_email,
    c.customer_name AS customer_name,
    c.market_id AS market_id,
    c.state AS state,
    c.city AS city,
    c.signup_channel AS signup_channel,
    o.acquisition_channel AS acquisition_channel,
    c.signup_date AS signup_date,
    ifNull(o.successful_order_count, toUInt64(0)) AS successful_order_count,
    ifNull(o.order_attempt_count, toUInt64(0)) AS order_attempt_count,
    ifNull(o.lifetime_net_revenue, toDecimal64(0, 2)) AS lifetime_net_revenue,
    ifNull(o.lifetime_contribution_margin, toDecimal64(0, 2)) AS lifetime_contribution_margin,
    o.first_order_date AS first_order_date,
    o.latest_order_date AS latest_order_date,
    if(
        o.first_order_date IS NULL,
        CAST(NULL, 'Nullable(Int32)'),
        toInt32(dateDiff('day', c.signup_date, o.first_order_date))
    ) AS days_to_first_order,
    toLowCardinality(
        multiIf(
            ifNull(o.lifetime_net_revenue, toDecimal64(0, 2)) >= toDecimal64(1000, 2), 'vip',
            ifNull(o.successful_order_count, 0) >= 5, 'loyal',
            ifNull(o.successful_order_count, 0) >= 2, 'repeat',
            ifNull(o.successful_order_count, 0) = 1, 'first_time',
            'prospect'
        )
    ) AS lifecycle_segment
FROM bruin_shop.t1_customers AS c
LEFT JOIN order_metrics AS o
    ON c.customer_id = o.customer_id
