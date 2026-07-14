/* @bruin
name: shop_rpt_special_event_impact
type: clickhouse.sql
materialization:
   type: table
depends:
    - shop_raw_special_events
    - shop_stg_orders
    - shop_stg_web_sessions
    - shop_stg_marketing_spend

columns:
  - name: event_id
    type: varchar
    primary_key: true
    checks:
        - name: not_null
        - name: unique
  - name: event_name
    type: varchar
  - name: event_type
    type: varchar
  - name: start_date
    type: date
  - name: end_date
    type: date
  - name: event_days
    type: integer
  - name: channel
    type: varchar
  - name: product_id
    type: varchar
  - name: event_sessions
    type: integer
  - name: event_checkouts
    type: integer
  - name: event_successful_orders
    type: integer
  - name: event_refunded_orders
    type: integer
  - name: event_net_revenue
    type: float
  - name: event_contribution_profit
    type: float
  - name: event_spend
    type: float
  - name: event_impressions
    type: integer
  - name: event_clicks
    type: integer
  - name: refund_rate
    type: float
  - name: roas
    type: float
  - name: conversion_rate
    type: float
  - name: baseline_daily_revenue
    type: float
  - name: event_daily_revenue
    type: float
  - name: daily_revenue_delta_pct
    type: float
@bruin */

WITH
    event_orders AS (
        SELECT
            e.event_id,
            countIf(o.is_successful_order = 1) AS event_successful_orders,
            countIf(o.has_refund = 1) AS event_refunded_orders,
            round(sum(o.net_revenue), 2) AS event_net_revenue,
            round(sum(o.contribution_profit), 2) AS event_contribution_profit
        FROM shop_raw_special_events AS e
        CROSS JOIN shop_stg_orders AS o
        WHERE o.order_date BETWEEN e.start_date AND e.end_date
            AND (e.channel = 'all' OR o.channel = e.channel)
            AND (e.product_id = 'all' OR o.product_id = e.product_id)
        GROUP BY e.event_id
    ),
    baseline_orders AS (
        SELECT
            e.event_id,
            countIf(o.is_successful_order = 1) AS baseline_successful_orders,
            round(sum(o.net_revenue), 2) AS baseline_net_revenue,
            round(sum(o.contribution_profit), 2) AS baseline_contribution_profit
        FROM shop_raw_special_events AS e
        CROSS JOIN shop_stg_orders AS o
        WHERE o.order_date >= e.start_date - INTERVAL 14 DAY
            AND o.order_date < e.start_date
            AND (e.channel = 'all' OR o.channel = e.channel)
            AND (e.product_id = 'all' OR o.product_id = e.product_id)
        GROUP BY e.event_id
    ),
    event_web AS (
        SELECT
            e.event_id,
            sum(w.sessions) AS event_sessions,
            sum(w.checkouts) AS event_checkouts
        FROM shop_raw_special_events AS e
        CROSS JOIN shop_stg_web_sessions AS w
        WHERE w.session_date BETWEEN e.start_date AND e.end_date
            AND (e.channel = 'all' OR w.channel = e.channel)
        GROUP BY e.event_id
    ),
    event_spend AS (
        SELECT
            e.event_id,
            round(sum(s.spend_amount), 2) AS event_spend,
            sum(s.impressions) AS event_impressions,
            sum(s.clicks) AS event_clicks
        FROM shop_raw_special_events AS e
        CROSS JOIN shop_stg_marketing_spend AS s
        WHERE s.spend_date BETWEEN e.start_date AND e.end_date
            AND (e.channel = 'all' OR s.channel = e.channel)
        GROUP BY e.event_id
    )
SELECT
    e.event_id AS event_id,
    e.event_name AS event_name,
    e.event_type AS event_type,
    e.start_date AS start_date,
    e.end_date AS end_date,
    dateDiff('day', e.start_date, e.end_date) + 1 AS event_days,
    e.channel AS channel,
    e.product_id AS product_id,
    ifNull(w.event_sessions, 0) AS event_sessions,
    ifNull(w.event_checkouts, 0) AS event_checkouts,
    ifNull(o.event_successful_orders, 0) AS event_successful_orders,
    ifNull(o.event_refunded_orders, 0) AS event_refunded_orders,
    ifNull(o.event_net_revenue, 0.00) AS event_net_revenue,
    ifNull(o.event_contribution_profit, 0.00) AS event_contribution_profit,
    ifNull(s.event_spend, 0.00) AS event_spend,
    ifNull(s.event_impressions, 0) AS event_impressions,
    ifNull(s.event_clicks, 0) AS event_clicks,
    round(if(event_successful_orders = 0, 0, event_refunded_orders / event_successful_orders), 4) AS refund_rate,
    round(if(event_spend = 0, 0, event_net_revenue / event_spend), 2) AS roas,
    round(if(event_sessions = 0, 0, event_successful_orders / event_sessions), 4) AS conversion_rate,
    round(ifNull(b.baseline_net_revenue, 0.00) / 14, 2) AS baseline_daily_revenue,
    round(event_net_revenue / event_days, 2) AS event_daily_revenue,
    round(if(baseline_daily_revenue = 0, 0, (event_daily_revenue - baseline_daily_revenue) / baseline_daily_revenue), 4) AS daily_revenue_delta_pct
FROM shop_raw_special_events AS e
LEFT JOIN event_orders AS o
    ON e.event_id = o.event_id
LEFT JOIN baseline_orders AS b
    ON e.event_id = b.event_id
LEFT JOIN event_web AS w
    ON e.event_id = w.event_id
LEFT JOIN event_spend AS s
    ON e.event_id = s.event_id
