/* @bruin
name: bruin_shop.t3_daily_kpis
type: clickhouse.sql
description: "T3 executive daily scorecard combining commerce, funnel, customer, and paid-media KPIs."
materialization:
  type: table
  strategy: time_interval
  incremental_key: metric_date
  time_granularity: date
depends:
  - bruin_shop.t3_daily_revenue
  - bruin_shop.t2_web_sessions
  - bruin_shop.t2_marketing_spend
  - bruin_shop.t2_customers

tags:
  - t3
  - mart
domains:
  - commerce
  - finance
  - marketing
meta:
  grain: one row per calendar date

custom_checks:
  - name: interval contains executive KPIs
    description: Ensures the requested interval contains scorecard rows.
    query: |
      SELECT count() > 0
      FROM bruin_shop.t3_daily_kpis
      WHERE metric_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
    value: 1
    blocking: true
  - name: contribution profit subtracts media
    description: Ensures paid-media spend is subtracted once, after order contribution margin.
    query: |
      SELECT metric_date
      FROM bruin_shop.t3_daily_kpis
      WHERE metric_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
        AND contribution_profit != contribution_margin - spend_amount
    count: 0
    blocking: true

columns:
  - name: metric_date
    type: Date
    description: "Calendar date represented by the KPI row."
    primary_key: true
    checks:
      - name: not_null
      - name: unique
  - name: order_attempts
    type: UInt64
    description: "Number of all order attempts."
  - name: successful_orders
    type: UInt64
    description: "Number of successfully captured orders."
  - name: net_revenue
    type: Decimal(18, 2)
    description: "Captured order totals net of refunds."
    checks:
      - name: non_negative
  - name: refund_amount
    type: Decimal(18, 2)
    description: "Amount returned to customers."
    checks:
      - name: non_negative
  - name: contribution_margin
    type: Decimal(18, 2)
    description: "Order contribution margin before paid-media spend."
  - name: spend_amount
    type: Decimal(18, 2)
    description: "Paid-media spend."
    checks:
      - name: non_negative
  - name: contribution_profit
    type: Decimal(18, 2)
    description: "Order contribution margin after paid-media spend."
  - name: average_order_value
    type: Decimal(18, 2)
    description: "Net revenue divided by successfully captured orders."
  - name: sessions
    type: UInt64
    description: "Web sessions."
  - name: product_views
    type: UInt64
    description: "Product-detail views."
  - name: add_to_carts
    type: UInt64
    description: "Sessions that added an item to cart."
  - name: checkouts
    type: UInt64
    description: "Sessions that reached checkout."
  - name: impressions
    type: UInt64
    description: "Paid-media impressions."
  - name: clicks
    type: UInt64
    description: "Paid-media clicks."
  - name: new_customers
    type: UInt64
    description: "Customers placing their first successfully captured order."
  - name: session_conversion_rate
    type: Float64
    description: "Successfully captured orders divided by web sessions."
    checks:
      - name: min
        value: 0
      - name: max
        value: 1
  - name: roas
    type: Float64
    description: "Net revenue divided by paid-media spend."
    checks:
      - name: non_negative
  - name: contribution_roas
    type: Float64
    description: "Order contribution margin divided by paid-media spend."
  - name: revenue_per_session
    type: Decimal(18, 2)
    description: "Net revenue divided by web sessions."
    checks:
      - name: non_negative
  - name: blended_customer_acquisition_cost
    type: Decimal(18, 2)
    description: "Paid-media spend divided by all newly acquired customers."
    checks:
      - name: non_negative
@bruin */

WITH
    web AS (
        SELECT
            session_date AS metric_date,
            sum(sessions) AS sessions,
            sum(product_views) AS product_views,
            sum(add_to_carts) AS add_to_carts,
            sum(checkouts) AS checkouts
        FROM bruin_shop.t2_web_sessions
        WHERE session_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
        GROUP BY session_date
    ),
    spend AS (
        SELECT
            spend_date AS metric_date,
            toDecimal64(sum(spend_amount), 2) AS spend_amount,
            sum(impressions) AS impressions,
            sum(clicks) AS clicks
        FROM bruin_shop.t2_marketing_spend
        WHERE spend_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
        GROUP BY spend_date
    ),
    customers AS (
        SELECT
            first_order_date AS metric_date,
            count() AS new_customers
        FROM bruin_shop.t2_customers
        WHERE first_order_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
        GROUP BY first_order_date
    ),
    joined AS (
        SELECT
            r.revenue_date AS revenue_date,
            r.order_attempts AS order_attempts,
            r.successful_orders AS successful_orders,
            r.net_revenue AS net_revenue,
            r.refund_amount AS refund_amount,
            r.contribution_margin AS contribution_margin,
            r.average_order_value AS average_order_value,
            ifNull(w.sessions, toUInt64(0)) AS sessions,
            ifNull(w.product_views, toUInt64(0)) AS product_views,
            ifNull(w.add_to_carts, toUInt64(0)) AS add_to_carts,
            ifNull(w.checkouts, toUInt64(0)) AS checkouts,
            ifNull(s.spend_amount, toDecimal64(0, 2)) AS spend_amount,
            ifNull(s.impressions, toUInt64(0)) AS impressions,
            ifNull(s.clicks, toUInt64(0)) AS clicks,
            ifNull(c.new_customers, toUInt64(0)) AS new_customers
        FROM bruin_shop.t3_daily_revenue AS r
        LEFT JOIN web AS w
            ON r.revenue_date = w.metric_date
        LEFT JOIN spend AS s
            ON r.revenue_date = s.metric_date
        LEFT JOIN customers AS c
            ON r.revenue_date = c.metric_date
        WHERE r.revenue_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
    )
SELECT
    revenue_date AS metric_date,
    order_attempts,
    successful_orders,
    net_revenue,
    refund_amount,
    contribution_margin,
    spend_amount,
    toDecimal64(contribution_margin - spend_amount, 2) AS contribution_profit,
    average_order_value,
    sessions,
    product_views,
    add_to_carts,
    checkouts,
    impressions,
    clicks,
    new_customers,
    round(
        if(sessions = 0, 0, toFloat64(successful_orders) / toFloat64(sessions)),
        4
    ) AS session_conversion_rate,
    round(if(spend_amount = 0, 0, toFloat64(net_revenue) / toFloat64(spend_amount)), 2) AS roas,
    round(
        if(spend_amount = 0, 0, toFloat64(contribution_margin) / toFloat64(spend_amount)),
        2
    ) AS contribution_roas,
    toDecimal64(if(sessions = 0, 0, toFloat64(net_revenue) / toFloat64(sessions)), 2) AS revenue_per_session,
    toDecimal64(
        if(new_customers = 0, 0, toFloat64(spend_amount) / toFloat64(new_customers)),
        2
    ) AS blended_customer_acquisition_cost
FROM joined
