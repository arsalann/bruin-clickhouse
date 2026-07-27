/* @bruin
name: bruin_shop.t3_marketing_roi
type: clickhouse.sql
description: "T3 paid-media ROI mart by date, market, channel, campaign, and event."
materialization:
  type: table
  strategy: time_interval
  incremental_key: spend_date
  time_granularity: date
depends:
  - bruin_shop.t2_marketing_spend
  - bruin_shop.t2_web_sessions
  - bruin_shop.t2_customers

tags:
  - t3
  - mart
domains:
  - marketing
  - finance
meta:
  grain: one row per date, market, and paid channel
  attribution_model: same-day last-channel synthetic

custom_checks:
  - name: interval contains marketing ROI
    description: Ensures the requested interval contains paid-media ROI rows.
    query: |
      SELECT count() > 0
      FROM bruin_shop.t3_marketing_roi
      WHERE spend_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
    value: 1
    blocking: true
  - name: marketing ROI grain is unique
    description: Ensures one ROI row per date, market, and paid channel.
    query: |
      SELECT spend_date, market_id, channel
      FROM bruin_shop.t3_marketing_roi
      WHERE spend_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
      GROUP BY spend_date, market_id, channel
      HAVING count() > 1
    count: 0
    blocking: true
  - name: media contribution profit reconciles
    description: Ensures paid-media spend is subtracted exactly once.
    query: |
      SELECT roi_id
      FROM bruin_shop.t3_marketing_roi
      WHERE spend_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
        AND contribution_profit != order_contribution_margin - spend_amount
    count: 0
    blocking: true

columns:
  - name: roi_id
    type: String
    description: "Stable identifier of the daily market-channel ROI grain."
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
  - name: spend_amount
    type: Decimal(18, 2)
    description: "Paid-media spend."
    checks:
      - name: non_negative
  - name: impressions
    type: UInt64
    description: "Paid-media impressions."
  - name: clicks
    type: UInt64
    description: "Paid-media clicks."
  - name: sessions
    type: UInt64
    description: "Attributed web sessions."
  - name: successful_orders
    type: UInt64
    description: "Same-day successfully captured attributed orders."
  - name: new_customers
    type: UInt64
    description: "First-time customers acquired through the market and channel."
  - name: net_revenue
    type: Decimal(18, 2)
    description: "Same-day attributed captured revenue net of refunds."
    checks:
      - name: non_negative
  - name: order_contribution_margin
    type: Decimal(18, 2)
    description: "Same-day attributed order contribution margin before media spend."
  - name: contribution_profit
    type: Decimal(18, 2)
    description: "Attributed order contribution margin after media spend."
  - name: roas
    type: Float64
    description: "Attributed net revenue divided by media spend."
    checks:
      - name: non_negative
  - name: contribution_roas
    type: Float64
    description: "Attributed order contribution margin divided by media spend."
  - name: profit_roas
    type: Float64
    description: "Contribution profit after media divided by media spend."
  - name: session_conversion_rate
    type: Float64
    description: "Successfully captured attributed orders divided by sessions."
    checks:
      - name: min
        value: 0
      - name: max
        value: 1
  - name: customer_acquisition_cost
    type: Decimal(18, 2)
    description: "Media spend divided by newly acquired customers."
    checks:
      - name: non_negative
@bruin */

WITH new_customers AS (
    SELECT
        first_order_date AS acquisition_date,
        market_id,
        acquisition_channel AS channel,
        count() AS new_customers
    FROM bruin_shop.t2_customers
    WHERE first_order_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
      AND acquisition_channel IN ('paid_search', 'paid_social')
    GROUP BY first_order_date, market_id, acquisition_channel
)
SELECT
    s.spend_id AS roi_id,
    s.spend_date AS spend_date,
    s.market_id AS market_id,
    s.state AS state,
    s.city AS city,
    s.channel AS channel,
    s.event_id AS event_id,
    s.campaign_id AS campaign_id,
    s.campaign_name AS campaign_name,
    s.spend_amount AS spend_amount,
    s.impressions AS impressions,
    s.clicks AS clicks,
    w.sessions AS sessions,
    w.successful_orders AS successful_orders,
    ifNull(c.new_customers, toUInt64(0)) AS new_customers,
    w.net_revenue AS net_revenue,
    w.contribution_margin AS order_contribution_margin,
    toDecimal64(w.contribution_margin - s.spend_amount, 2) AS contribution_profit,
    round(toFloat64(w.net_revenue) / toFloat64(s.spend_amount), 2) AS roas,
    round(toFloat64(w.contribution_margin) / toFloat64(s.spend_amount), 2) AS contribution_roas,
    round(toFloat64(contribution_profit) / toFloat64(s.spend_amount), 2) AS profit_roas,
    round(
        if(w.sessions = 0, 0, toFloat64(w.successful_orders) / toFloat64(w.sessions)),
        4
    ) AS session_conversion_rate,
    toDecimal64(
        if(new_customers = 0, 0, toFloat64(s.spend_amount) / toFloat64(new_customers)),
        2
    ) AS customer_acquisition_cost
FROM bruin_shop.t2_marketing_spend AS s
INNER JOIN bruin_shop.t2_web_sessions AS w
    ON s.spend_date = w.session_date
    AND s.market_id = w.market_id
    AND s.channel = w.channel
LEFT JOIN new_customers AS c
    ON s.spend_date = c.acquisition_date
    AND s.market_id = c.market_id
    AND s.channel = c.channel
WHERE s.spend_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
