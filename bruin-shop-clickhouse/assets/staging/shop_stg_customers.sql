/* @bruin
name: shop_stg_customers
type: clickhouse.sql
materialization:
   type: table
depends:
    - shop_raw_customers
    - shop_stg_orders

columns:
  - name: customer_id
    type: integer
    primary_key: true
    checks:
        - name: not_null
        - name: unique
  - name: customer_email
    type: varchar
  - name: customer_name
    type: varchar
  - name: market_id
    type: varchar
  - name: state
    type: varchar
  - name: city
    type: varchar
  - name: acquisition_channel
    type: varchar
  - name: signup_date
    type: date
  - name: successful_order_count
    type: integer
  - name: order_attempt_count
    type: integer
  - name: lifetime_net_revenue
    type: float
  - name: lifetime_contribution_profit
    type: float
  - name: first_order_date
    type: date
  - name: latest_order_date
    type: date
  - name: days_to_first_order
    type: integer
  - name: lifecycle_segment
    type: varchar
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
    FROM shop_stg_orders
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
FROM shop_raw_customers AS c
LEFT JOIN order_metrics AS o
    ON c.customer_id = o.customer_id
