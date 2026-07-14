/* @bruin
name: shop_rpt_marketing_roi
type: clickhouse.sql
materialization:
   type: table
depends:
    - shop_stg_marketing_spend
    - shop_stg_web_sessions
    - shop_stg_orders

columns:
  - name: roi_id
    type: varchar
    primary_key: true
    checks:
        - name: not_null
        - name: unique
  - name: spend_date
    type: date
  - name: market_id
    type: varchar
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
  - name: spend_amount
    type: float
  - name: impressions
    type: integer
  - name: clicks
    type: integer
  - name: sessions
    type: integer
  - name: successful_orders
    type: integer
  - name: net_revenue
    type: float
  - name: contribution_profit
    type: float
  - name: roas
    type: float
  - name: profit_roas
    type: float
  - name: conversion_rate
    type: float
@bruin */

WITH orders AS (
    SELECT
        order_date,
        market_id,
        channel,
        countIf(is_successful_order = 1) AS successful_orders,
        round(sum(net_revenue), 2) AS net_revenue,
        round(sum(contribution_profit), 2) AS contribution_profit
    FROM shop_stg_orders
    GROUP BY
        order_date,
        market_id,
        channel
)
SELECT
    concat(toString(s.spend_date), '_', s.market_id, '_', s.channel) AS roi_id,
    s.spend_date AS spend_date,
    s.market_id AS market_id,
    s.state AS state,
    s.city AS city,
    s.channel AS channel,
    s.event_id AS event_id,
    s.campaign_id AS campaign_id,
    s.spend_amount AS spend_amount,
    s.impressions AS impressions,
    s.clicks AS clicks,
    w.sessions AS sessions,
    ifNull(o.successful_orders, 0) AS successful_orders,
    ifNull(o.net_revenue, 0.00) AS net_revenue,
    ifNull(o.contribution_profit, 0.00) AS contribution_profit,
    round(if(s.spend_amount = 0, 0, net_revenue / s.spend_amount), 2) AS roas,
    round(if(s.spend_amount = 0, 0, contribution_profit / s.spend_amount), 2) AS profit_roas,
    round(if(w.sessions = 0, 0, successful_orders / w.sessions), 4) AS conversion_rate
FROM shop_stg_marketing_spend AS s
LEFT JOIN shop_stg_web_sessions AS w
    ON s.spend_date = w.session_date
    AND s.market_id = w.market_id
    AND s.channel = w.channel
LEFT JOIN orders AS o
    ON s.spend_date = o.order_date
    AND s.market_id = o.market_id
    AND s.channel = o.channel
