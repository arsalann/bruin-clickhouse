/* @bruin
name: shop_rpt_daily_kpis
type: clickhouse.sql
materialization:
   type: table
depends:
    - shop_rpt_daily_revenue
    - shop_stg_web_sessions
    - shop_stg_marketing_spend
    - shop_stg_customers

columns:
  - name: metric_date
    type: date
    primary_key: true
    checks:
        - name: not_null
        - name: unique
  - name: order_attempts
    type: integer
  - name: successful_orders
    type: integer
  - name: net_revenue
    type: float
  - name: refund_amount
    type: float
  - name: contribution_profit
    type: float
  - name: average_order_value
    type: float
  - name: sessions
    type: integer
  - name: product_views
    type: integer
  - name: add_to_carts
    type: integer
  - name: checkouts
    type: integer
  - name: spend_amount
    type: float
  - name: impressions
    type: integer
  - name: clicks
    type: integer
  - name: new_customers
    type: integer
  - name: conversion_rate
    type: float
  - name: roas
    type: float
  - name: revenue_per_session
    type: float
@bruin */

WITH
    web AS (
        SELECT
            session_date AS metric_date,
            sum(sessions) AS sessions,
            sum(product_views) AS product_views,
            sum(add_to_carts) AS add_to_carts,
            sum(checkouts) AS checkouts
        FROM shop_stg_web_sessions
        GROUP BY session_date
    ),
    spend AS (
        SELECT
            spend_date AS metric_date,
            round(sum(spend_amount), 2) AS spend_amount,
            sum(impressions) AS impressions,
            sum(clicks) AS clicks
        FROM shop_stg_marketing_spend
        GROUP BY spend_date
    ),
    customers AS (
        SELECT
            first_order_date AS metric_date,
            count() AS new_customers
        FROM shop_stg_customers
        WHERE first_order_date != toDate('1970-01-01')
        GROUP BY first_order_date
    )
SELECT
    r.revenue_date AS metric_date,
    r.order_attempts AS order_attempts,
    r.successful_orders AS successful_orders,
    r.net_revenue AS net_revenue,
    r.refund_amount AS refund_amount,
    r.contribution_profit AS contribution_profit,
    r.average_order_value AS average_order_value,
    ifNull(w.sessions, 0) AS sessions,
    ifNull(w.product_views, 0) AS product_views,
    ifNull(w.add_to_carts, 0) AS add_to_carts,
    ifNull(w.checkouts, 0) AS checkouts,
    ifNull(s.spend_amount, 0.00) AS spend_amount,
    ifNull(s.impressions, 0) AS impressions,
    ifNull(s.clicks, 0) AS clicks,
    ifNull(c.new_customers, 0) AS new_customers,
    round(if(sessions = 0, 0, successful_orders / sessions), 4) AS conversion_rate,
    round(if(spend_amount = 0, 0, net_revenue / spend_amount), 2) AS roas,
    round(if(sessions = 0, 0, net_revenue / sessions), 2) AS revenue_per_session
FROM shop_rpt_daily_revenue AS r
LEFT JOIN web AS w
    ON r.revenue_date = w.metric_date
LEFT JOIN spend AS s
    ON r.revenue_date = s.metric_date
LEFT JOIN customers AS c
    ON r.revenue_date = c.metric_date
