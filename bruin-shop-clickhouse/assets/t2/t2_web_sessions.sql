/* @bruin
name: bruin_shop.t2_web_sessions
type: clickhouse.sql
description: "Conformed T2 web funnel with same-day channel-attributed orders and revenue."
materialization:
  type: table
  strategy: time_interval
  incremental_key: session_date
  time_granularity: date
depends:
  - bruin_shop.t1_web_sessions
  - bruin_shop.t2_orders

tags:
  - t2
  - conformed
domains:
  - commerce
  - marketing
meta:
  grain: one row per date, market, and acquisition channel
  attribution_model: same-day last-channel synthetic

custom_checks:
  - name: interval contains funnel rows
    description: Ensures the requested interval contains standardized web-funnel rows.
    query: |
      SELECT count() > 0
      FROM bruin_shop.t2_web_sessions
      WHERE session_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
    value: 1
    blocking: true
  - name: attributed orders fit the funnel
    description: Ensures order attempts and successful orders do not exceed modeled checkouts.
    query: |
      SELECT session_id
      FROM bruin_shop.t2_web_sessions
      WHERE session_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
        AND (
          successful_orders > order_attempts
          OR order_attempts > checkouts
        )
    count: 0
    blocking: true

columns:
  - name: session_id
    type: String
    description: "Stable identifier of the daily market-channel grain."
    primary_key: true
    checks:
      - name: not_null
      - name: unique
  - name: session_date
    type: Date
    description: "Calendar date represented by the web activity."
  - name: market_id
    type: String
    description: "Stable identifier of the city market."
  - name: market_index
    type: UInt8
    description: "Stable numeric market ordering."
  - name: state
    type: LowCardinality(String)
    description: "Two-letter US state code."
  - name: city
    type: LowCardinality(String)
    description: "City represented by the market."
  - name: channel
    type: LowCardinality(String)
    description: "Normalized acquisition channel."
    checks:
      - name: accepted_values
        value: ["direct", "email", "organic", "paid_search", "paid_social"]
  - name: event_id
    type: LowCardinality(String)
    description: "Campaign or operational scenario active for the row, or `none`."
  - name: campaign_id
    type: LowCardinality(String)
    description: "Campaign or non-paid source identifier."
  - name: sessions
    type: UInt64
    description: "Number of web sessions."
    checks:
      - name: positive
  - name: product_views
    type: UInt64
    description: "Number of product-detail views."
    checks:
      - name: non_negative
  - name: add_to_carts
    type: UInt64
    description: "Number of sessions that added an item to cart."
    checks:
      - name: non_negative
  - name: checkouts
    type: UInt64
    description: "Number of sessions that reached checkout."
    checks:
      - name: non_negative
  - name: order_attempts
    type: UInt64
    description: "Same-day order attempts attributed to this market and channel."
    checks:
      - name: non_negative
  - name: successful_orders
    type: UInt64
    description: "Same-day successfully captured orders attributed to this market and channel."
    checks:
      - name: non_negative
  - name: net_revenue
    type: Decimal(18, 2)
    description: "Same-day captured revenue net of refunds."
    checks:
      - name: non_negative
  - name: contribution_margin
    type: Decimal(18, 2)
    description: "Same-day contribution margin before paid-media spend."
  - name: checkout_conversion_rate
    type: Float64
    description: "Order attempts divided by checkouts."
    checks:
      - name: min
        value: 0
      - name: max
        value: 1
  - name: session_conversion_rate
    type: Float64
    description: "Successfully captured orders divided by sessions."
    checks:
      - name: min
        value: 0
      - name: max
        value: 1
  - name: revenue_per_session
    type: Decimal(18, 2)
    description: "Net revenue divided by sessions."
    checks:
      - name: non_negative
@bruin */

WITH attributed_orders AS (
    SELECT
        order_date,
        market_id,
        channel,
        count() AS order_attempts,
        countIf(is_successful_order = 1) AS successful_orders,
        toDecimal64(sum(net_revenue), 2) AS net_revenue,
        toDecimal64(sum(contribution_margin), 2) AS contribution_margin
    FROM bruin_shop.t2_orders
    WHERE order_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
    GROUP BY order_date, market_id, channel
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
    ifNull(o.order_attempts, toUInt64(0)) AS order_attempts,
    ifNull(o.successful_orders, toUInt64(0)) AS successful_orders,
    ifNull(o.net_revenue, toDecimal64(0, 2)) AS net_revenue,
    ifNull(o.contribution_margin, toDecimal64(0, 2)) AS contribution_margin,
    round(
        if(s.checkouts = 0, 0, toFloat64(order_attempts) / toFloat64(s.checkouts)),
        4
    ) AS checkout_conversion_rate,
    round(
        if(s.sessions = 0, 0, toFloat64(successful_orders) / toFloat64(s.sessions)),
        4
    ) AS session_conversion_rate,
    toDecimal64(
        if(s.sessions = 0, 0, toFloat64(net_revenue) / toFloat64(s.sessions)),
        2
    ) AS revenue_per_session
FROM bruin_shop.t1_web_sessions AS s
LEFT JOIN attributed_orders AS o
    ON s.session_date = o.order_date
    AND s.market_id = o.market_id
    AND s.channel = o.channel
WHERE s.session_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
