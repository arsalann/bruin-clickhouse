/* @bruin
name: bruin_shop.t1_web_sessions
type: clickhouse.sql
description: "T1 daily web-funnel activity by market, channel, campaign, and event."
materialization:
   type: table
   strategy: append
depends:
    - bruin_shop.t1_marketing_spend
    - bruin_shop.t1_special_events
    - bruin_shop.t1_web_sessions_delete_interval

custom_checks:
  - name: contains rows
    description: Ensures the materialized table is not empty.
    query: SELECT count() > 0 FROM bruin_shop.t1_web_sessions
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
@bruin */

WITH base AS (
    SELECT
        s.spend_date AS session_date,
        s.market_id AS market_id,
        s.market_index AS market_index,
        s.state AS state,
        s.city AS city,
        s.channel AS channel,
        s.event_id AS event_id,
        s.campaign_id AS campaign_id,
        s.impressions AS impressions,
        s.clicks AS clicks,
        if(e.event_id = '', 1.0, e.session_multiplier) AS session_multiplier,
        round(
            multiIf(
                s.channel IN ('paid_search', 'paid_social', 'email'), greatest(toFloat64(s.clicks), 1.0) * 1.85,
                s.channel = 'organic', toFloat64(s.impressions) * 0.105,
                toFloat64(s.impressions) * 0.076
            )
            * if(e.event_id = '', 1.0, e.session_multiplier),
            0
        ) AS modeled_sessions
    FROM bruin_shop.t1_marketing_spend AS s
    LEFT JOIN bruin_shop.t1_special_events AS e
        ON s.event_id = e.event_id
    WHERE s.spend_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
)
SELECT
    concat(toString(session_date), '_', market_id, '_', channel) AS session_id,
    session_date,
    market_id,
    market_index,
    state,
    city,
    channel,
    event_id,
    campaign_id,
    toUInt64(greatest(modeled_sessions, 1)) AS sessions,
    toUInt64(round(greatest(modeled_sessions, 1) * 2.35)) AS product_views,
    toUInt64(round(greatest(modeled_sessions, 1) * multiIf(channel = 'email', 0.185, channel IN ('paid_search', 'paid_social'), 0.135, 0.092))) AS add_to_carts,
    toUInt64(round(greatest(modeled_sessions, 1) * multiIf(channel = 'email', 0.088, channel IN ('paid_search', 'paid_social'), 0.069, 0.043))) AS checkouts
FROM base
SETTINGS insert_deduplicate = 0
