/* @bruin
name: shop_stg_web_sessions
type: clickhouse.sql
materialization:
   type: table
depends:
    - shop_raw_web_sessions
    - shop_stg_orders

columns:
  - name: session_id
    type: varchar
    primary_key: true
    checks:
        - name: not_null
        - name: unique
  - name: session_date
    type: date
  - name: market_id
    type: varchar
  - name: market_index
    type: integer
  - name: state
    type: varchar
  - name: city
    type: varchar
  - name: channel
    type: varchar
  - name: event_id
    type: varchar
  - name: campaign_id
    type: varchar
  - name: sessions
    type: integer
  - name: product_views
    type: integer
  - name: add_to_carts
    type: integer
  - name: checkouts
    type: integer
  - name: successful_orders
    type: integer
  - name: net_revenue
    type: float
  - name: session_conversion_rate
    type: float
@bruin */

WITH order_rollup AS (
    SELECT
        order_date AS session_date,
        market_id,
        channel,
        countIf(is_successful_order = 1) AS successful_orders,
        sum(net_revenue) AS net_revenue
    FROM shop_stg_orders
    GROUP BY
        order_date,
        market_id,
        channel
)
SELECT
    s.session_id AS session_id,
    s.session_date AS session_date,
    s.market_id AS market_id,
    s.market_index AS market_index,
    s.state AS state,
    s.city AS city,
    s.channel AS channel,
    s.event_id AS event_id,
    s.campaign_id AS campaign_id,
    s.sessions AS sessions,
    s.product_views AS product_views,
    s.add_to_carts AS add_to_carts,
    s.checkouts AS checkouts,
    ifNull(o.successful_orders, 0) AS successful_orders,
    round(ifNull(o.net_revenue, 0.00), 2) AS net_revenue,
    round(if(s.sessions = 0, 0, ifNull(o.successful_orders, 0) / s.sessions), 4) AS session_conversion_rate
FROM shop_raw_web_sessions AS s
LEFT JOIN order_rollup AS o
    ON s.session_date = o.session_date
    AND s.market_id = o.market_id
    AND s.channel = o.channel
