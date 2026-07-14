/* @bruin
name: shop_stg_marketing_spend
type: clickhouse.sql
materialization:
   type: table
depends:
    - shop_raw_marketing_spend

columns:
  - name: spend_id
    type: varchar
    primary_key: true
    checks:
        - name: not_null
        - name: unique
  - name: spend_date
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
  - name: campaign_name
    type: varchar
  - name: impressions
    type: integer
  - name: clicks
    type: integer
  - name: spend_amount
    type: float
  - name: is_paid_media
    type: integer
  - name: click_through_rate
    type: float
  - name: cost_per_click
    type: float
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
FROM shop_raw_marketing_spend
