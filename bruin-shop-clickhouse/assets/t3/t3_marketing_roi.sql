/* @bruin
name: bruin_shop.t3_marketing_roi
type: clickhouse.sql
description: "T3 daily marketing ROI mart by market, channel, campaign, and event."
materialization:
   type: table
   strategy: append
depends:
    - bruin_shop.t2_marketing_spend
    - bruin_shop.t2_web_sessions
    - bruin_shop.t2_orders
    - bruin_shop.t3_marketing_roi_delete_interval

custom_checks:
  - name: contains rows
    description: Ensures the materialized table is not empty.
    query: SELECT count() > 0 FROM bruin_shop.t3_marketing_roi
    value: 1
    blocking: true
  - name: marketing ROI grain is unique
    description: Ensures there is at most one ROI row per date, market, channel, event, and campaign.
    query: |
      SELECT spend_date, market_id, channel, event_id, campaign_id
      FROM bruin_shop.t3_marketing_roi
      GROUP BY spend_date, market_id, channel, event_id, campaign_id
      HAVING count() > 1
    count: 0
    blocking: true
columns:
  - name: roi_id
    type: varchar
    description: "Stable identifier of the marketing ROI grain."
    primary_key: true
    checks:
        - name: not_null
        - name: unique
  - name: spend_date
    type: date
    description: "Calendar date on which the marketing spend occurred."
  - name: market_id
    type: varchar
    description: "Identifier of the market."
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
  - name: sessions
    type: integer
    description: "Number of web sessions."
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
  - name: contribution_profit
    type: float
    description: "Net revenue less variable marketing, fulfilment, and product costs."
  - name: roas
    type: float
    description: "Net revenue divided by marketing spend."
    checks:
      - name: non_negative
  - name: profit_roas
    type: float
    description: "Contribution profit divided by marketing spend."
  - name: conversion_rate
    type: float
    description: "Successful orders divided by sessions for the period."
    checks:
      - name: min
        value: 0
      - name: max
        value: 1
      - name: min
        value: 0
      - name: max
        value: 1
@bruin */

WITH orders AS (
    SELECT
        order_date,
        market_id,
        channel,
        countIf(is_successful_order = 1) AS successful_orders,
        round(sum(net_revenue), 2) AS net_revenue,
        round(sum(contribution_profit), 2) AS contribution_profit
    FROM bruin_shop.t2_orders
    WHERE order_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
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
FROM bruin_shop.t2_marketing_spend AS s
LEFT JOIN bruin_shop.t2_web_sessions AS w
    ON s.spend_date = w.session_date
    AND s.market_id = w.market_id
    AND s.channel = w.channel
LEFT JOIN orders AS o
    ON s.spend_date = o.order_date
    AND s.market_id = o.market_id
    AND s.channel = o.channel
WHERE s.spend_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
SETTINGS insert_deduplicate = 0
