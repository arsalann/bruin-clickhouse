/* @bruin
name: shop_raw_marketing_spend
type: clickhouse.sql
materialization:
   type: table
depends:
    - shop_raw_markets
    - shop_raw_special_events

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
@bruin */

WITH
    toDate('2026-01-01') AS start_date,
    toDate('2026-06-30') AS end_date,
    date_spine AS (
        SELECT addDays(start_date, toUInt16(number)) AS spend_date
        FROM numbers(dateDiff('day', start_date, end_date) + 1)
    ),
    channels AS (
        SELECT arrayJoin(['paid_search', 'paid_social', 'email', 'organic', 'direct']) AS channel
    ),
    base AS (
        SELECT
            d.spend_date AS spend_date,
            m.market_id AS market_id,
            m.market_index AS market_index,
            m.state AS state,
            m.city AS city,
            c.channel AS channel,
            multiIf(
                c.channel = 'paid_search' AND d.spend_date BETWEEN toDate('2026-01-12') AND toDate('2026-01-18'), 'paid_search_broad_match_failure',
                d.spend_date = toDate('2026-02-04'), 'checkout_outage',
                d.spend_date BETWEEN toDate('2026-02-20') AND toDate('2026-02-24'), 'product_defect_black_tote',
                c.channel = 'paid_social' AND d.spend_date BETWEEN toDate('2026-03-10') AND toDate('2026-03-17'), 'trail_shoe_launch',
                c.channel = 'paid_social' AND d.spend_date BETWEEN toDate('2026-03-18') AND toDate('2026-03-21'), 'trail_shoe_stockout',
                c.channel = 'paid_social' AND d.spend_date BETWEEN toDate('2026-04-08') AND toDate('2026-04-14'), 'spring_outfit_campaign',
                c.channel = 'paid_search' AND d.spend_date BETWEEN toDate('2026-05-11') AND toDate('2026-05-17'), 'memorial_day_search',
                c.channel = 'paid_search' AND d.spend_date BETWEEN toDate('2026-06-07') AND toDate('2026-06-08'), 'google_summer_sale',
                'none'
            ) AS event_id,
            multiIf(
                c.channel = 'paid_search' AND d.spend_date BETWEEN toDate('2026-01-12') AND toDate('2026-01-18'), 'Google search broad-match failure',
                d.spend_date = toDate('2026-02-04'), 'Checkout outage and recovery',
                d.spend_date BETWEEN toDate('2026-02-20') AND toDate('2026-02-24'), 'Black Tote Bag defect refund incident',
                c.channel = 'paid_social' AND d.spend_date BETWEEN toDate('2026-03-10') AND toDate('2026-03-17'), 'Instagram trail shoe launch',
                c.channel = 'paid_social' AND d.spend_date BETWEEN toDate('2026-03-18') AND toDate('2026-03-21'), 'Instagram trail shoe stockout',
                c.channel = 'paid_social' AND d.spend_date BETWEEN toDate('2026-04-08') AND toDate('2026-04-14'), 'Instagram spring outfit campaign',
                c.channel = 'paid_search' AND d.spend_date BETWEEN toDate('2026-05-11') AND toDate('2026-05-17'), 'Google Memorial Day search campaign',
                c.channel = 'paid_search' AND d.spend_date BETWEEN toDate('2026-06-07') AND toDate('2026-06-08'), 'Google Search - Summer Sale',
                'Always-on traffic'
            ) AS campaign_name,
            multiIf(
                c.channel = 'paid_search' AND d.spend_date BETWEEN toDate('2026-01-12') AND toDate('2026-01-18'), 1.08,
                c.channel = 'paid_social' AND d.spend_date BETWEEN toDate('2026-03-10') AND toDate('2026-03-17'), 1.35,
                c.channel = 'paid_social' AND d.spend_date BETWEEN toDate('2026-03-18') AND toDate('2026-03-21'), 1.18,
                c.channel = 'paid_social' AND d.spend_date BETWEEN toDate('2026-04-08') AND toDate('2026-04-14'), 1.25,
                c.channel = 'paid_search' AND d.spend_date BETWEEN toDate('2026-05-11') AND toDate('2026-05-17'), 1.30,
                c.channel = 'paid_search' AND d.spend_date BETWEEN toDate('2026-06-07') AND toDate('2026-06-08'), 1.45,
                1.00
            ) AS spend_multiplier,
            multiIf(
                c.channel = 'paid_search' AND d.spend_date BETWEEN toDate('2026-01-12') AND toDate('2026-01-18'), 0.42,
                d.spend_date = toDate('2026-02-04'), 0.18,
                c.channel = 'paid_social' AND d.spend_date BETWEEN toDate('2026-03-10') AND toDate('2026-03-17'), 1.70,
                c.channel = 'paid_social' AND d.spend_date BETWEEN toDate('2026-03-18') AND toDate('2026-03-21'), 0.20,
                c.channel = 'paid_social' AND d.spend_date BETWEEN toDate('2026-04-08') AND toDate('2026-04-14'), 1.38,
                c.channel = 'paid_search' AND d.spend_date BETWEEN toDate('2026-05-11') AND toDate('2026-05-17'), 1.42,
                c.channel = 'paid_search' AND d.spend_date BETWEEN toDate('2026-06-07') AND toDate('2026-06-08'), 1.55,
                1.00
            ) AS conversion_multiplier,
            round(
                multiIf(
                    c.channel = 'paid_search', 1180,
                    c.channel = 'paid_social', 1420,
                    c.channel = 'email', 760,
                    c.channel = 'organic', 3100,
                    1850
                )
                * m.demand_weight
                * (1 + toFloat64(cityHash64(toString(d.spend_date), m.market_id, c.channel) % 19) / 100),
                2
            ) AS base_impressions,
            multiIf(
                c.channel = 'paid_search', 0.044,
                c.channel = 'paid_social', 0.032,
                c.channel = 'email', 0.082,
                c.channel = 'organic', 0.035,
                0.029
            ) AS base_ctr,
            multiIf(
                c.channel = 'paid_search', 105.00,
                c.channel = 'paid_social', 92.00,
                c.channel = 'email', 16.00,
                0.00
            ) * m.demand_weight AS base_spend
        FROM date_spine AS d
        CROSS JOIN shop_raw_markets AS m
        CROSS JOIN channels AS c
        CROSS JOIN (SELECT count() AS event_catalog_rows FROM shop_raw_special_events) AS event_catalog
    )
SELECT
    concat(toString(spend_date), '_', market_id, '_', channel) AS spend_id,
    spend_date,
    market_id,
    market_index,
    state,
    city,
    channel,
    event_id,
    multiIf(
        event_id != 'none', event_id,
        channel = 'paid_search', 'google_always_on',
        channel = 'paid_social', 'meta_always_on',
        channel = 'email', 'owned_email_lifecycle',
        channel = 'organic', 'organic_nonpaid',
        'direct_nonpaid'
    ) AS campaign_id,
    campaign_name,
    toUInt64(round(base_impressions * spend_multiplier)) AS impressions,
    toUInt64(round(base_impressions * spend_multiplier * base_ctr * least(conversion_multiplier, 1.25))) AS clicks,
    round(base_spend * spend_multiplier, 2) AS spend_amount
FROM base
