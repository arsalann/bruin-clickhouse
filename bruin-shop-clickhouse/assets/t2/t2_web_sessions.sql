/* @bruin
name: bruin_shop.t2_web_sessions
type: clickhouse.sql
description: "T2 web-funnel fact enriched with attributed orders, revenue, and conversion rate."
materialization:
   type: table
   strategy: append
depends:
    - bruin_shop.t1_web_sessions
    - bruin_shop.t2_orders
    - bruin_shop.t2_web_sessions_delete_interval

custom_checks:
  - name: contains rows
    description: Ensures the materialized table is not empty.
    query: SELECT count() > 0 FROM bruin_shop.t2_web_sessions
    value: 1
    blocking: true
columns:
  - name: session_id
    type: varchar
    description: "Stable identifier of the web-session grain."
    primary_key: true
    checks:
        - name: not_null
        - name: unique
  - name: session_date
    type: date
    description: "Calendar date represented by the web-session activity."
  - name: market_id
    type: varchar
    description: "Identifier of the market."
  - name: market_index
    type: integer
    description: "Stable numeric ordering of the market."
  - name: state
    type: varchar
    description: "State associated with the market or customer."
  - name: city
    type: varchar
    description: "City associated with the market or customer."
  - name: channel
    type: varchar
    description: "Marketing or acquisition channel associated with the record."
    checks:
      - name: accepted_values
        value: ["direct", "email", "organic", "paid_search", "paid_social"]
  - name: event_id
    type: varchar
    description: "Identifier of the associated special event."
  - name: campaign_id
    type: varchar
    description: "Identifier of the marketing campaign associated with the record."
  - name: sessions
    type: integer
    description: "Number of web sessions."
    checks:
      - name: non_negative
  - name: product_views
    type: integer
    description: "Number of product-detail views."
    checks:
      - name: non_negative
  - name: add_to_carts
    type: integer
    description: "Number of sessions that added at least one item to the cart."
    checks:
      - name: non_negative
  - name: checkouts
    type: integer
    description: "Number of sessions that reached the checkout step."
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
  - name: session_conversion_rate
    type: float
    description: "Successful orders divided by web sessions."
    checks:
      - name: min
        value: 0
      - name: max
        value: 1
@bruin */

WITH order_rollup AS (
    SELECT
        order_date AS session_date,
        market_id,
        channel,
        countIf(is_successful_order = 1) AS successful_orders,
        sum(net_revenue) AS net_revenue
    FROM bruin_shop.t2_orders
    WHERE order_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
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
FROM bruin_shop.t1_web_sessions AS s
LEFT JOIN order_rollup AS o
    ON s.session_date = o.session_date
    AND s.market_id = o.market_id
    AND s.channel = o.channel
WHERE s.session_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
SETTINGS insert_deduplicate = 0
