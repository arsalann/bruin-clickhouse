/* @bruin
name: shop_raw_web_sessions
type: clickhouse.sql
materialization:
   type: table
depends:
    - shop_raw_marketing_spend
    - shop_raw_special_events

columns:
  - name: session_id
    type: varchar
    primary_key: true
    checks:
        - name: not_null
        - name: unique
  - name: session_date
    type: date
  - name: market_id
    type: varchar
  - name: market_index
    type: integer
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
  - name: sessions
    type: integer
  - name: product_views
    type: integer
  - name: add_to_carts
    type: integer
  - name: checkouts
    type: integer
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
    FROM shop_raw_marketing_spend AS s
    LEFT JOIN shop_raw_special_events AS e
        ON s.event_id = e.event_id
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
