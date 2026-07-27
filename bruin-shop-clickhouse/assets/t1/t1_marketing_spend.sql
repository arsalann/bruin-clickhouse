/* @bruin
name: bruin_shop.t1_marketing_spend
type: clickhouse.sql
description: "Synthetic ad-platform T1 delivery and spend at daily market-channel grain."
materialization:
  type: table
  strategy: time_interval
  incremental_key: spend_date
  time_granularity: date
depends:
  - bruin_shop.t1_markets
  - bruin_shop.t1_special_events

tags:
  - t1
  - source
  - synthetic
domains:
  - marketing
meta:
  grain: one row per date, market, and paid channel
  source_system: synthetic_ad_platforms

custom_checks:
  - name: interval contains paid media
    description: Ensures every requested interval produces paid-search and paid-social rows.
    query: |
      SELECT count() > 0
      FROM bruin_shop.t1_marketing_spend
      WHERE spend_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
    value: 1
    blocking: true
  - name: clicks do not exceed impressions
    description: Ensures paid-media delivery follows a valid funnel.
    query: |
      SELECT spend_id
      FROM bruin_shop.t1_marketing_spend
      WHERE spend_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
        AND clicks > impressions
    count: 0
    blocking: true
columns:
  - name: spend_id
    type: String
    description: "Stable identifier of the daily market-channel grain."
    primary_key: true
    checks:
      - name: not_null
      - name: unique
  - name: spend_date
    type: Date
    description: "Calendar date on which media delivery occurred."
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
    description: "Paid acquisition channel."
    checks:
      - name: accepted_values
        value: ["paid_search", "paid_social"]
  - name: event_id
    type: LowCardinality(String)
    description: "Campaign scenario active for the row, or `none`."
  - name: campaign_id
    type: LowCardinality(String)
    description: "Stable paid-media campaign identifier."
  - name: campaign_name
    type: LowCardinality(String)
    description: "Human-readable paid-media campaign name."
  - name: impressions
    type: UInt64
    description: "Number of ad impressions."
    checks:
      - name: non_negative
  - name: clicks
    type: UInt64
    description: "Number of ad clicks."
    checks:
      - name: non_negative
  - name: spend_amount
    type: Decimal(18, 2)
    description: "Paid-media spend in USD."
    checks:
      - name: non_negative
@bruin */

WITH
    toDate('{{ start_date }}') AS interval_start,
    toDate('{{ end_date }}') AS interval_end,
    date_spine AS (
        SELECT addDays(interval_start, toUInt16(number)) AS spend_date
        FROM numbers(dateDiff('day', interval_start, interval_end) + 1)
    ),
    channels AS (
        SELECT arrayJoin(['paid_search', 'paid_social']) AS channel
    ),
    modeled AS (
        SELECT
            d.spend_date AS spend_date,
            m.market_id AS market_id,
            m.market_index AS market_index,
            m.state AS state,
            m.city AS city,
            c.channel AS channel,
            if(e.event_id = '', 'none', e.event_id) AS event_id,
            if(e.event_id = '', '', e.event_name) AS event_name,
            if(e.event_id = '', 1.0, e.spend_multiplier) AS spend_multiplier,
            if(e.event_id = '', 1.0, e.conversion_multiplier) AS click_quality_multiplier,
            round(
                multiIf(c.channel = 'paid_search', 1180.0, 1420.0)
                * m.demand_weight
                * (1 + toFloat64(cityHash64(toString(d.spend_date), m.market_id, c.channel, 'impressions') % 19) / 100),
                2
            ) AS base_impressions,
            multiIf(c.channel = 'paid_search', 0.044, 0.032) AS base_ctr,
            multiIf(c.channel = 'paid_search', 105.00, 92.00) * m.demand_weight AS base_spend
        FROM date_spine AS d
        CROSS JOIN bruin_shop.t1_markets AS m
        CROSS JOIN channels AS c
        LEFT JOIN bruin_shop.t1_special_events AS e
            ON e.channel = c.channel
            AND d.spend_date BETWEEN e.start_date AND e.end_date
            AND e.event_type IN ('campaign_failure', 'campaign_win')
    )
SELECT
    concat(toString(spend_date), '_', market_id, '_', channel) AS spend_id,
    spend_date,
    market_id,
    market_index,
    state,
    city,
    toLowCardinality(channel) AS channel,
    toLowCardinality(event_id) AS event_id,
    toLowCardinality(
        multiIf(
            event_id != 'none', event_id,
            channel = 'paid_search', 'google_always_on',
            'meta_always_on'
        )
    ) AS campaign_id,
    toLowCardinality(
        multiIf(
            event_id != 'none', event_name,
            channel = 'paid_search', 'Google Search - Always On',
            'Meta - Always On'
        )
    ) AS campaign_name,
    toUInt64(round(base_impressions * spend_multiplier)) AS impressions,
    toUInt64(round(base_impressions * spend_multiplier * base_ctr * least(click_quality_multiplier, 1.25))) AS clicks,
    toDecimal64(base_spend * spend_multiplier, 2) AS spend_amount
FROM modeled
