/* @bruin
name: bruin_shop.t3_daily_kpis
type: clickhouse.sql
description: "T3 executive daily KPI mart combining commerce, web-funnel, and marketing performance."
materialization:
   type: table
   strategy: append
depends:
    - bruin_shop.t3_daily_revenue
    - bruin_shop.t2_web_sessions
    - bruin_shop.t2_marketing_spend
    - bruin_shop.t2_customers
    - bruin_shop.t3_daily_kpis_delete_interval

custom_checks:
  - name: contains rows
    description: Ensures the materialized table is not empty.
    query: SELECT count() > 0 FROM bruin_shop.t3_daily_kpis
    value: 1
    blocking: true
columns:
  - name: metric_date
    type: date
    description: "Calendar date represented by the KPI row."
    primary_key: true
    checks:
        - name: not_null
        - name: unique
  - name: order_attempts
    type: integer
    description: "Number of order attempts in the period."
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
  - name: refund_amount
    type: float
    description: "Monetary value refunded to the customer."
    checks:
      - name: non_negative
  - name: contribution_profit
    type: float
    description: "Net revenue less variable marketing, fulfilment, and product costs."
  - name: average_order_value
    type: float
    description: "Average net revenue per successful order."
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
  - name: spend_amount
    type: float
    description: "Marketing spend amount."
    checks:
      - name: non_negative
  - name: impressions
    type: integer
    description: "Number of advertising or campaign impressions."
    checks:
      - name: non_negative
  - name: clicks
    type: integer
    description: "Number of advertising or campaign clicks."
    checks:
      - name: non_negative
  - name: new_customers
    type: integer
    description: "Customers whose first successful order occurred on the date."
    checks:
      - name: non_negative
  - name: conversion_rate
    type: float
    description: "Successful orders divided by sessions for the period."
    checks:
      - name: min
        value: 0
      - name: max
        value: 1
  - name: roas
    type: float
    description: "Net revenue divided by marketing spend."
    checks:
      - name: non_negative
  - name: revenue_per_session
    type: float
    description: "Net revenue divided by web sessions."
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
            round(sum(spend_amount), 2) AS spend_amount,
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
FROM bruin_shop.t3_daily_revenue AS r
LEFT JOIN web AS w
    ON r.revenue_date = w.metric_date
LEFT JOIN spend AS s
    ON r.revenue_date = s.metric_date
LEFT JOIN customers AS c
    ON r.revenue_date = c.metric_date
WHERE r.revenue_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
SETTINGS insert_deduplicate = 0
