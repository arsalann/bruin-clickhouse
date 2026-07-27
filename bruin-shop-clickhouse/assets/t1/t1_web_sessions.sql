/* @bruin
name: bruin_shop.t1_web_sessions
type: clickhouse.sql
description: "Synthetic GA4-style T1 funnel activity at daily market-channel grain."
materialization:
  type: table
  strategy: time_interval
  incremental_key: session_date
  time_granularity: date
depends:
  - bruin_shop.t1_marketing_spend
  - bruin_shop.t1_markets
  - bruin_shop.t1_special_events

tags:
  - t1
  - source
  - synthetic
domains:
  - commerce
  - marketing
meta:
  grain: one row per date, market, and acquisition channel
  source_system: synthetic_ga4

custom_checks:
  - name: interval contains web activity
    description: Ensures every requested interval produces web-funnel rows.
    query: |
      SELECT count() > 0
      FROM bruin_shop.t1_web_sessions
      WHERE session_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
    value: 1
    blocking: true
  - name: funnel steps are ordered
    description: Ensures product views, carts, and checkouts form a possible funnel.
    query: |
      SELECT session_id
      FROM bruin_shop.t1_web_sessions
      WHERE session_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
        AND (
          product_views < sessions
          OR add_to_carts > sessions
          OR checkouts > add_to_carts
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
    description: "Stable numeric market ordering used by synthetic keys."
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
      - name: non_negative
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
@bruin */

WITH
    toDate('{{ start_date }}') AS interval_start,
    toDate('{{ end_date }}') AS interval_end,
    date_spine AS (
        SELECT addDays(interval_start, toUInt16(number)) AS session_date
        FROM numbers(dateDiff('day', interval_start, interval_end) + 1)
    ),
    channels AS (
        SELECT arrayJoin(['direct', 'email', 'organic', 'paid_search', 'paid_social']) AS channel
    ),
    event_calendar AS (
        SELECT
            addDays(e.start_date, toUInt16(day_offset)) AS event_date,
            c.channel AS channel,
            e.event_id AS event_id,
            e.session_multiplier AS session_multiplier
        FROM bruin_shop.t1_special_events AS e
        CROSS JOIN channels AS c
        ARRAY JOIN range(toUInt32(dateDiff('day', e.start_date, e.end_date) + 1)) AS day_offset
        WHERE e.channel = 'all' OR e.channel = c.channel
    ),
    modeled AS (
        SELECT
            d.session_date AS session_date,
            m.market_id AS market_id,
            m.market_index AS market_index,
            m.state AS state,
            m.city AS city,
            c.channel AS channel,
            if(e.event_id = '', 'none', e.event_id) AS event_id,
            multiIf(
                c.channel IN ('paid_search', 'paid_social'), s.campaign_id,
                c.channel = 'email', 'owned_email_lifecycle',
                c.channel = 'organic', 'organic_nonpaid',
                'direct_nonpaid'
            ) AS campaign_id,
            round(
                multiIf(
                    c.channel IN ('paid_search', 'paid_social'), greatest(toFloat64(s.clicks), 1.0) * 1.85,
                    c.channel = 'email', 145.0 * m.demand_weight,
                    c.channel = 'organic', 335.0 * m.demand_weight,
                    175.0 * m.demand_weight
                )
                * (0.90 + toFloat64(cityHash64(toString(d.session_date), m.market_id, c.channel, 'sessions') % 21) / 100)
                * if(e.event_id = '', 1.0, e.session_multiplier),
                0
            ) AS modeled_sessions
        FROM date_spine AS d
        CROSS JOIN bruin_shop.t1_markets AS m
        CROSS JOIN channels AS c
        LEFT JOIN bruin_shop.t1_marketing_spend AS s
            ON s.spend_date = d.session_date
            AND s.market_id = m.market_id
            AND s.channel = c.channel
        LEFT JOIN event_calendar AS e
            ON d.session_date = e.event_date
            AND c.channel = e.channel
    )
SELECT
    concat(toString(session_date), '_', market_id, '_', channel) AS session_id,
    session_date,
    market_id,
    market_index,
    state,
    city,
    toLowCardinality(channel) AS channel,
    toLowCardinality(event_id) AS event_id,
    toLowCardinality(campaign_id) AS campaign_id,
    toUInt64(greatest(modeled_sessions, 1)) AS sessions,
    toUInt64(round(greatest(modeled_sessions, 1) * 2.35)) AS product_views,
    toUInt64(
        round(
            greatest(modeled_sessions, 1)
            * multiIf(channel = 'email', 0.185, channel IN ('paid_search', 'paid_social'), 0.135, 0.092)
        )
    ) AS add_to_carts,
    toUInt64(
        round(
            greatest(modeled_sessions, 1)
            * multiIf(channel = 'email', 0.088, channel IN ('paid_search', 'paid_social'), 0.069, 0.043)
        )
    ) AS checkouts
FROM modeled
