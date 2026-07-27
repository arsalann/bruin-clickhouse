/* @bruin
name: bruin_shop.t2_marketing_spend
type: clickhouse.sql
description: "T2 standardized daily marketing spend with paid-media and efficiency measures."
materialization:
   type: table
   strategy: append
depends:
    - bruin_shop.t1_marketing_spend
    - bruin_shop.t2_marketing_spend_delete_interval

custom_checks:
  - name: contains rows
    description: Ensures the materialized table is not empty.
    query: SELECT count() > 0 FROM bruin_shop.t2_marketing_spend
    value: 1
    blocking: true
  - name: marketing spend grain is unique
    description: Ensures there is at most one standardized spend row per date, market, channel, event, and campaign.
    query: |
      SELECT spend_date, market_id, channel, event_id, campaign_id
      FROM bruin_shop.t2_marketing_spend
      GROUP BY spend_date, market_id, channel, event_id, campaign_id
      HAVING count() > 1
    count: 0
    blocking: true
columns:
  - name: spend_id
    type: varchar
    description: "Stable identifier of the marketing-spend grain."
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
  - name: campaign_name
    type: varchar
    description: "Human-readable name of the associated marketing campaign."
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
  - name: spend_amount
    type: float
    description: "Marketing spend amount."
    checks:
      - name: non_negative
  - name: is_paid_media
    type: integer
    description: "Whether the channel is paid media."
  - name: click_through_rate
    type: float
    description: "Clicks divided by impressions for the marketing activity."
    checks:
      - name: non_negative
  - name: cost_per_click
    type: float
    description: "Marketing spend divided by clicks."
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
    toUInt8(channel IN ('paid_search', 'paid_social')) AS is_paid_media,
    round(if(impressions = 0, 0, clicks / impressions), 4) AS click_through_rate,
    round(if(clicks = 0, 0, spend_amount / clicks), 4) AS cost_per_click
FROM bruin_shop.t1_marketing_spend
WHERE spend_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
SETTINGS insert_deduplicate = 0
