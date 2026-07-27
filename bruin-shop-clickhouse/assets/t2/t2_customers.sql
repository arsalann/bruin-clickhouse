/* @bruin
name: bruin_shop.t2_customers
type: clickhouse.sql
description: "T2 customer dimension enriched with lifecycle and lifetime-value metrics."
materialization:
   type: table
   strategy: truncate+insert
depends:
    - bruin_shop.t1_customers
    - bruin_shop.t2_orders

custom_checks:
  - name: contains rows
    description: Ensures the materialized table is not empty.
    query: SELECT count() > 0 FROM bruin_shop.t2_customers
    value: 1
    blocking: true
columns:
  - name: customer_id
    type: integer
    description: "Stable identifier of the customer."
    primary_key: true
    checks:
        - name: not_null
        - name: unique
  - name: customer_email
    type: varchar
    description: "Email address associated with the customer or order."
  - name: customer_name
    type: varchar
    description: "Display name of the customer."
  - name: market_id
    type: varchar
    description: "Identifier of the market."
  - name: state
    type: varchar
    description: "State associated with the market or customer."
  - name: city
    type: varchar
    description: "City associated with the market or customer."
  - name: acquisition_channel
    type: varchar
    description: "Marketing channel credited with acquiring the customer."
  - name: signup_date
    type: date
    description: "Date on which the customer signed up."
  - name: successful_order_count
    type: integer
    description: "Number of successful orders made by the customer."
    checks:
      - name: non_negative
  - name: order_attempt_count
    type: integer
    description: "Number of order attempts made by the customer."
    checks:
      - name: non_negative
  - name: lifetime_net_revenue
    type: float
    description: "Customer net revenue accumulated over successful orders."
  - name: lifetime_contribution_profit
    type: float
    description: "Customer contribution profit accumulated over successful orders."
  - name: first_order_date
    type: date
    description: "Date of the customer\u2019s first successful order."
  - name: latest_order_date
    type: date
    description: "Date of the customer\u2019s most recent successful order."
  - name: days_to_first_order
    type: integer
    description: "Days between customer signup and first successful order."
  - name: lifecycle_segment
    type: varchar
    description: "Customer lifecycle segment derived from order behavior."
@bruin */

WITH order_metrics AS (
    SELECT
        customer_id,
        countIf(is_successful_order = 1) AS successful_order_count,
        count() AS order_attempt_count,
        sum(net_revenue) AS lifetime_net_revenue,
        sum(contribution_profit) AS lifetime_contribution_profit,
        minIf(order_date, is_successful_order = 1) AS first_order_date,
        maxIf(order_date, is_successful_order = 1) AS latest_order_date
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
    c.acquisition_channel AS acquisition_channel,
    c.signup_date AS signup_date,
    ifNull(o.successful_order_count, 0) AS successful_order_count,
    ifNull(o.order_attempt_count, 0) AS order_attempt_count,
    round(ifNull(o.lifetime_net_revenue, 0.00), 2) AS lifetime_net_revenue,
    round(ifNull(o.lifetime_contribution_profit, 0.00), 2) AS lifetime_contribution_profit,
    o.first_order_date AS first_order_date,
    o.latest_order_date AS latest_order_date,
    if(o.first_order_date = toDate('1970-01-01'), NULL, dateDiff('day', c.signup_date, o.first_order_date)) AS days_to_first_order,
    multiIf(
        ifNull(o.lifetime_net_revenue, 0) >= 950, 'vip',
        ifNull(o.successful_order_count, 0) >= 3, 'loyal',
        ifNull(o.successful_order_count, 0) = 2, 'repeat',
        ifNull(o.successful_order_count, 0) = 1, 'first_time',
        'prospect'
    ) AS lifecycle_segment
FROM bruin_shop.t1_customers AS c
LEFT JOIN order_metrics AS o
    ON c.customer_id = o.customer_id
