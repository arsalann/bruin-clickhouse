/* @bruin
name: bruin_shop.t3_special_event_impact
type: clickhouse.sql
description: "T3 event-impact mart comparing scoped event performance with the preceding 14-day baseline."
materialization:
  type: table
  strategy: create+replace
depends:
  - bruin_shop.t1_special_events
  - bruin_shop.t2_orders
  - bruin_shop.t2_order_line_items
  - bruin_shop.t2_web_sessions
  - bruin_shop.t2_marketing_spend

tags:
  - t3
  - mart
domains:
  - commerce
  - marketing
  - finance
meta:
  grain: one row per special event
  baseline: preceding 14 calendar days

custom_checks:
  - name: preserves the event catalog
    description: Ensures every configured scenario appears in the impact mart.
    query: SELECT count() FROM bruin_shop.t3_special_event_impact
    value: 8
    blocking: true
  - name: event contribution profit reconciles
    description: Ensures event-period paid-media spend is subtracted exactly once.
    query: |
      SELECT event_id
      FROM bruin_shop.t3_special_event_impact
      WHERE event_contribution_profit != event_order_contribution_margin - event_spend
    count: 0
    blocking: true

columns:
  - name: event_id
    type: String
    description: "Stable identifier of the special event."
    primary_key: true
    checks:
      - name: not_null
      - name: unique
  - name: event_name
    type: LowCardinality(String)
    description: "Human-readable event name."
  - name: event_type
    type: LowCardinality(String)
    description: "Classification of the scenario."
  - name: start_date
    type: Date
    description: "First date of the event."
  - name: end_date
    type: Date
    description: "Last date of the event."
  - name: event_days
    type: UInt16
    description: "Inclusive calendar days in the event."
    checks:
      - name: positive
  - name: baseline_days
    type: UInt8
    description: "Calendar days in the pre-event comparison window."
    checks:
      - name: positive
  - name: channel
    type: LowCardinality(String)
    description: "Channel scope, or `all`."
  - name: product_id
    type: String
    description: "Product scope, or `all`."
  - name: order_scope
    type: LowCardinality(String)
    description: "Whether metrics include all orders or orders containing the selected product."
    checks:
      - name: accepted_values
        value: ["all_orders", "orders_containing_product"]
  - name: event_sessions
    type: UInt64
    description: "Web sessions in the event's date and channel scope."
  - name: event_checkouts
    type: UInt64
    description: "Checkouts in the event's date and channel scope."
  - name: event_successful_orders
    type: UInt64
    description: "Successfully captured orders in the event's order scope."
  - name: event_refunded_orders
    type: UInt64
    description: "Refunded orders in the event's order scope."
  - name: event_net_revenue
    type: Decimal(18, 2)
    description: "Full-order net revenue from orders in the event's order scope."
    checks:
      - name: non_negative
  - name: event_order_contribution_margin
    type: Decimal(18, 2)
    description: "Full-order contribution margin before media for orders in event scope."
  - name: event_spend
    type: Decimal(18, 2)
    description: "Paid-media spend in the event's date and channel scope."
    checks:
      - name: non_negative
  - name: event_contribution_profit
    type: Decimal(18, 2)
    description: "Event order contribution margin after event-period media spend."
  - name: event_impressions
    type: UInt64
    description: "Paid-media impressions in the event's date and channel scope."
  - name: event_clicks
    type: UInt64
    description: "Paid-media clicks in the event's date and channel scope."
  - name: refund_rate
    type: Float64
    description: "Refunded scoped orders divided by successful scoped orders."
    checks:
      - name: min
        value: 0
      - name: max
        value: 1
  - name: roas
    type: Float64
    description: "Scoped event net revenue divided by event-period media spend."
    checks:
      - name: non_negative
  - name: contribution_roas
    type: Float64
    description: "Scoped order contribution margin divided by event-period media spend."
  - name: profit_roas
    type: Float64
    description: "Event contribution profit after media divided by event-period media spend."
  - name: session_conversion_rate
    type: Float64
    description: "Scoped successful orders divided by channel-scoped sessions."
    checks:
      - name: min
        value: 0
      - name: max
        value: 1
  - name: baseline_successful_orders
    type: UInt64
    description: "Successful scoped orders in the preceding 14 days."
  - name: baseline_net_revenue
    type: Decimal(18, 2)
    description: "Scoped net revenue in the preceding 14 days."
    checks:
      - name: non_negative
  - name: baseline_order_contribution_margin
    type: Decimal(18, 2)
    description: "Scoped order contribution margin in the preceding 14 days."
  - name: baseline_daily_net_revenue
    type: Decimal(18, 2)
    description: "Average daily scoped net revenue in the preceding 14 days."
    checks:
      - name: non_negative
  - name: event_daily_net_revenue
    type: Decimal(18, 2)
    description: "Average daily scoped net revenue during the event."
    checks:
      - name: non_negative
  - name: daily_revenue_delta_pct
    type: Float64
    description: "Event daily net revenue change relative to the preceding baseline."
@bruin */

WITH
    order_products AS (
        SELECT DISTINCT order_id, product_id
        FROM bruin_shop.t2_order_line_items
    ),
    all_order_scopes AS (
        SELECT
            e.event_id AS event_id,
            toUInt8(o.order_date >= e.start_date) AS is_event_period,
            o.order_id AS order_id,
            o.is_successful_order AS is_successful_order,
            o.has_refund AS has_refund,
            o.net_revenue AS net_revenue,
            o.contribution_margin AS contribution_margin
        FROM bruin_shop.t1_special_events AS e
        CROSS JOIN bruin_shop.t2_orders AS o
        WHERE e.product_id = 'all'
          AND o.order_date BETWEEN e.start_date - INTERVAL 14 DAY AND e.end_date
          AND (e.channel = 'all' OR o.channel = e.channel)
    ),
    product_order_scopes AS (
        SELECT
            e.event_id AS event_id,
            toUInt8(o.order_date >= e.start_date) AS is_event_period,
            o.order_id AS order_id,
            o.is_successful_order AS is_successful_order,
            o.has_refund AS has_refund,
            o.net_revenue AS net_revenue,
            o.contribution_margin AS contribution_margin
        FROM bruin_shop.t1_special_events AS e
        INNER JOIN order_products AS p
            ON e.product_id = p.product_id
        INNER JOIN bruin_shop.t2_orders AS o
            ON p.order_id = o.order_id
        WHERE e.product_id != 'all'
          AND o.order_date BETWEEN e.start_date - INTERVAL 14 DAY AND e.end_date
          AND (e.channel = 'all' OR o.channel = e.channel)
    ),
    scoped_orders AS (
        SELECT * FROM all_order_scopes
        UNION ALL
        SELECT * FROM product_order_scopes
    ),
    order_metrics AS (
        SELECT
            event_id,
            countIf(is_event_period = 1 AND is_successful_order = 1) AS event_successful_orders,
            countIf(is_event_period = 1 AND has_refund = 1) AS event_refunded_orders,
            toDecimal64(sumIf(net_revenue, is_event_period = 1), 2) AS event_net_revenue,
            toDecimal64(sumIf(contribution_margin, is_event_period = 1), 2) AS event_order_contribution_margin,
            countIf(is_event_period = 0 AND is_successful_order = 1) AS baseline_successful_orders,
            toDecimal64(sumIf(net_revenue, is_event_period = 0), 2) AS baseline_net_revenue,
            toDecimal64(sumIf(contribution_margin, is_event_period = 0), 2) AS baseline_order_contribution_margin
        FROM scoped_orders
        GROUP BY event_id
    ),
    web_metrics AS (
        SELECT
            e.event_id AS event_id,
            sum(w.sessions) AS event_sessions,
            sum(w.checkouts) AS event_checkouts
        FROM bruin_shop.t1_special_events AS e
        CROSS JOIN bruin_shop.t2_web_sessions AS w
        WHERE w.session_date BETWEEN e.start_date AND e.end_date
          AND (e.channel = 'all' OR w.channel = e.channel)
        GROUP BY e.event_id
    ),
    spend_metrics AS (
        SELECT
            e.event_id AS event_id,
            toDecimal64(sum(s.spend_amount), 2) AS event_spend,
            sum(s.impressions) AS event_impressions,
            sum(s.clicks) AS event_clicks
        FROM bruin_shop.t1_special_events AS e
        CROSS JOIN bruin_shop.t2_marketing_spend AS s
        WHERE s.spend_date BETWEEN e.start_date AND e.end_date
          AND (e.channel = 'all' OR s.channel = e.channel)
        GROUP BY e.event_id
    ),
    joined AS (
        SELECT
            e.event_id AS event_id,
            e.event_name AS event_name,
            e.event_type AS event_type,
            e.start_date AS start_date,
            e.end_date AS end_date,
            e.channel AS channel,
            e.product_id AS product_id,
            toUInt16(dateDiff('day', e.start_date, e.end_date) + 1) AS event_days,
            toUInt8(14) AS baseline_days,
            toLowCardinality(if(e.product_id = 'all', 'all_orders', 'orders_containing_product')) AS order_scope,
            ifNull(w.event_sessions, toUInt64(0)) AS event_sessions,
            ifNull(w.event_checkouts, toUInt64(0)) AS event_checkouts,
            ifNull(o.event_successful_orders, toUInt64(0)) AS event_successful_orders,
            ifNull(o.event_refunded_orders, toUInt64(0)) AS event_refunded_orders,
            ifNull(o.event_net_revenue, toDecimal64(0, 2)) AS event_net_revenue,
            ifNull(o.event_order_contribution_margin, toDecimal64(0, 2)) AS event_order_contribution_margin,
            ifNull(s.event_spend, toDecimal64(0, 2)) AS event_spend,
            ifNull(s.event_impressions, toUInt64(0)) AS event_impressions,
            ifNull(s.event_clicks, toUInt64(0)) AS event_clicks,
            ifNull(o.baseline_successful_orders, toUInt64(0)) AS baseline_successful_orders,
            ifNull(o.baseline_net_revenue, toDecimal64(0, 2)) AS baseline_net_revenue,
            ifNull(o.baseline_order_contribution_margin, toDecimal64(0, 2)) AS baseline_order_contribution_margin
        FROM bruin_shop.t1_special_events AS e
        LEFT JOIN order_metrics AS o
            ON e.event_id = o.event_id
        LEFT JOIN web_metrics AS w
            ON e.event_id = w.event_id
        LEFT JOIN spend_metrics AS s
            ON e.event_id = s.event_id
    ),
    daily AS (
        SELECT
            *,
            toDecimal64(event_order_contribution_margin - event_spend, 2) AS event_contribution_profit,
            toDecimal64(toFloat64(baseline_net_revenue) / toFloat64(baseline_days), 2) AS baseline_daily_net_revenue,
            toDecimal64(toFloat64(event_net_revenue) / toFloat64(event_days), 2) AS event_daily_net_revenue
        FROM joined
    )
SELECT
    event_id,
    event_name,
    event_type,
    start_date,
    end_date,
    event_days,
    baseline_days,
    channel,
    product_id,
    order_scope,
    event_sessions,
    event_checkouts,
    event_successful_orders,
    event_refunded_orders,
    event_net_revenue,
    event_order_contribution_margin,
    event_spend,
    event_contribution_profit,
    event_impressions,
    event_clicks,
    round(
        if(event_successful_orders = 0, 0, toFloat64(event_refunded_orders) / toFloat64(event_successful_orders)),
        4
    ) AS refund_rate,
    round(if(event_spend = 0, 0, toFloat64(event_net_revenue) / toFloat64(event_spend)), 2) AS roas,
    round(
        if(event_spend = 0, 0, toFloat64(event_order_contribution_margin) / toFloat64(event_spend)),
        2
    ) AS contribution_roas,
    round(
        if(event_spend = 0, 0, toFloat64(event_contribution_profit) / toFloat64(event_spend)),
        2
    ) AS profit_roas,
    round(
        if(event_sessions = 0, 0, toFloat64(event_successful_orders) / toFloat64(event_sessions)),
        4
    ) AS session_conversion_rate,
    baseline_successful_orders,
    baseline_net_revenue,
    baseline_order_contribution_margin,
    baseline_daily_net_revenue,
    event_daily_net_revenue,
    round(
        if(
            baseline_daily_net_revenue = 0,
            0,
            (toFloat64(event_daily_net_revenue) - toFloat64(baseline_daily_net_revenue))
                / toFloat64(baseline_daily_net_revenue)
        ),
        4
    ) AS daily_revenue_delta_pct
FROM daily
