/* @bruin
name: bruin_shop.t2_marketing_spend
type: clickhouse.sql
description: "Conformed T2 paid-media delivery with click-through and cost-per-click measures."
materialization:
  type: table
  strategy: time_interval
  incremental_key: spend_date
  time_granularity: date
depends:
  - bruin_shop.t1_marketing_spend

tags:
  - t2
  - conformed
domains:
  - marketing
meta:
  grain: one row per date, market, and paid channel
  source_system: conformed_ad_platforms

custom_checks:
  - name: interval contains paid media
    description: Ensures the requested interval contains standardized paid-media rows.
    query: |
      SELECT count() > 0
      FROM bruin_shop.t2_marketing_spend
      WHERE spend_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
    value: 1
    blocking: true
  - name: paid media grain is unique
    description: Ensures one row per date, market, and paid channel.
    query: |
      SELECT spend_date, market_id, channel
      FROM bruin_shop.t2_marketing_spend
      WHERE spend_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
      GROUP BY spend_date, market_id, channel
      HAVING count() > 1
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
    description: "Stable numeric market ordering."
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
    description: "Human-readable campaign name."
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
  - name: click_through_rate
    type: Float64
    description: "Clicks divided by impressions."
    checks:
      - name: min
        value: 0
      - name: max
        value: 1
  - name: cost_per_click
    type: Decimal(18, 2)
    description: "Paid-media spend divided by clicks."
    checks:
      - name: non_negative
@bruin */

SELECT
    spend_id,
    spend_date,
    market_id,
    market_index,
    state,
    city,
    channel,
    event_id,
    campaign_id,
    campaign_name,
    impressions,
    clicks,
    spend_amount,
    round(if(impressions = 0, 0, toFloat64(clicks) / toFloat64(impressions)), 4) AS click_through_rate,
    toDecimal64(if(clicks = 0, 0, toFloat64(spend_amount) / toFloat64(clicks)), 2) AS cost_per_click
FROM bruin_shop.t1_marketing_spend
WHERE spend_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
