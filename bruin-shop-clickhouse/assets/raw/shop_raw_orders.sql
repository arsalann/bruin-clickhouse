/* @bruin
name: shop_raw_orders
type: clickhouse.sql
materialization:
   type: table
depends:
    - shop_raw_web_sessions
    - shop_raw_special_events
    - shop_raw_products
    - shop_raw_customers
    - shop_raw_markets

columns:
  - name: order_id
    type: integer
    primary_key: true
    checks:
        - name: not_null
        - name: unique
  - name: order_name
    type: varchar
  - name: customer_id
    type: integer
  - name: customer_email
    type: varchar
  - name: order_date
    type: date
  - name: order_datetime
    type: datetime
  - name: market_id
    type: varchar
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
  - name: product_id
    type: varchar
  - name: product_name
    type: varchar
  - name: product_category
    type: varchar
  - name: item_count
    type: integer
  - name: order_status
    type: varchar
  - name: financial_status
    type: varchar
  - name: fulfillment_status
    type: varchar
  - name: gross_merchandise_amount
    type: float
  - name: discount_amount
    type: float
  - name: tax_amount
    type: float
  - name: shipping_revenue
    type: float
  - name: shipping_cost
    type: float
  - name: cogs_amount
    type: float
  - name: total_amount
    type: float
@bruin */

WITH
    [
        'prod_tshirt_01', 'prod_tshirt_02', 'prod_tshirt_03', 'prod_tshirt_04',
        'prod_pants_01', 'prod_pants_02', 'prod_pants_03', 'prod_pants_04',
        'prod_shoes_01', 'prod_shoes_02', 'prod_shoes_03', 'prod_shoes_04',
        'prod_accessories_01', 'prod_accessories_02', 'prod_accessories_03', 'prod_accessories_04',
        'prod_accessories_05', 'prod_accessories_06', 'prod_accessories_07', 'prod_accessories_09'
    ] AS product_ids,
    [
        'prod_tshirt_01', 'prod_tshirt_02', 'prod_tshirt_03', 'prod_tshirt_04',
        'prod_pants_01', 'prod_pants_02', 'prod_pants_03', 'prod_pants_04',
        'prod_shoes_01', 'prod_shoes_02', 'prod_shoes_03',
        'prod_accessories_01', 'prod_accessories_02', 'prod_accessories_03', 'prod_accessories_04',
        'prod_accessories_05', 'prod_accessories_06', 'prod_accessories_07', 'prod_accessories_09'
    ] AS non_trail_shoe_products,
    order_groups AS (
        SELECT
            s.session_date AS order_date,
            s.market_id AS market_id,
            s.market_index AS market_index,
            s.state AS state,
            s.city AS city,
            s.channel AS channel,
            s.event_id AS event_id,
            s.campaign_id AS campaign_id,
            s.sessions AS sessions,
            if(e.event_id = '', 'all', e.product_id) AS event_product_id,
            if(e.event_id = '', 1.0, e.conversion_multiplier) AS conversion_multiplier,
            toUInt32(greatest(
                round(
                    toFloat64(s.sessions)
                    * multiIf(
                        s.channel = 'email', 0.052,
                        s.channel = 'paid_search', 0.041,
                        s.channel = 'paid_social', 0.036,
                        s.channel = 'organic', 0.028,
                        0.024
                    )
                    * if(e.event_id = '', 1.0, e.conversion_multiplier),
                    0
                ),
                0
            )) AS order_count
        FROM shop_raw_web_sessions AS s
        LEFT JOIN shop_raw_special_events AS e
            ON s.event_id = e.event_id
    ),
    exploded AS (
        SELECT
            order_date,
            market_id,
            market_index,
            state,
            city,
            channel,
            event_id,
            campaign_id,
            order_number,
            cityHash64(toString(order_date), market_id, channel, toString(order_number)) AS order_hash
        FROM order_groups
        ARRAY JOIN range(order_count) AS order_number
    ),
    selected AS (
        SELECT
            *,
            multiIf(
                event_id = 'trail_shoe_launch' AND channel = 'paid_social' AND order_hash % 100 < 68,
                    'prod_shoes_04',
                event_id = 'trail_shoe_stockout' AND channel = 'paid_social',
                    arrayElement(non_trail_shoe_products, toUInt32((order_hash % length(non_trail_shoe_products)) + 1)),
                event_id = 'product_defect_black_tote' AND order_hash % 100 < 72,
                    'prod_accessories_09',
                arrayElement(product_ids, toUInt32((order_hash % length(product_ids)) + 1))
            ) AS product_id,
            toUInt8(1 + (order_hash % 4)) AS item_count,
            toUInt64(market_index + 12 * (order_hash % 665)) AS customer_id
        FROM exploded
    ),
    priced AS (
        SELECT
            s.order_date AS order_date,
            s.market_id AS market_id,
            s.market_index AS market_index,
            s.state AS state,
            s.city AS city,
            s.channel AS channel,
            s.event_id AS event_id,
            s.campaign_id AS campaign_id,
            s.order_number AS order_number,
            s.order_hash AS order_hash,
            s.product_id AS product_id,
            s.item_count AS item_count,
            s.customer_id AS customer_id,
            c.customer_email AS customer_email,
            p.product_name AS product_name,
            p.category AS product_category,
            p.list_price AS list_price,
            p.unit_cogs AS unit_cogs,
            round(p.list_price * s.item_count, 2) AS gross_merchandise_amount,
            round(
                p.list_price
                * s.item_count
                * multiIf(s.channel = 'email', 0.12, s.channel IN ('paid_search', 'paid_social'), 0.08, 0.02),
                2
            ) AS discount_amount,
            round(p.unit_cogs * s.item_count, 2) AS cogs_amount
        FROM selected AS s
        INNER JOIN shop_raw_products AS p
            ON s.product_id = p.product_id
        INNER JOIN shop_raw_customers AS c
            ON s.customer_id = c.customer_id
    )
SELECT
    toUInt64(po.order_hash) AS order_id,
    concat('#', toString(100000 + (po.order_hash % 900000))) AS order_name,
    po.customer_id,
    po.customer_email,
    po.order_date,
    toDateTime(po.order_date) + toIntervalSecond(toUInt32(po.order_hash % 78000)) AS order_datetime,
    po.market_id,
    po.state,
    po.city,
    po.channel,
    po.event_id,
    po.campaign_id,
    po.product_id,
    po.product_name,
    po.product_category,
    po.item_count,
    multiIf(
        po.event_id = 'product_defect_black_tote' AND po.product_id = 'prod_accessories_09' AND po.order_hash % 100 < 96, 'partially_refunded',
        po.order_hash % 100 < 2, 'cancelled',
        po.order_hash % 100 < 5, 'refunded',
        'paid'
    ) AS order_status,
    multiIf(order_status = 'cancelled', 'voided', order_status IN ('refunded', 'partially_refunded'), 'refunded', 'paid') AS financial_status,
    multiIf(order_status = 'cancelled', 'cancelled', po.order_hash % 100 < 14, 'unfulfilled', 'fulfilled') AS fulfillment_status,
    po.gross_merchandise_amount,
    po.discount_amount,
    round((po.gross_merchandise_amount - po.discount_amount) * m.tax_rate, 2) AS tax_amount,
    multiIf(po.gross_merchandise_amount - po.discount_amount >= 90, 0.00, 6.95) AS shipping_revenue,
    round(po.item_count * 2.65, 2) AS shipping_cost,
    po.cogs_amount,
    round(po.gross_merchandise_amount - po.discount_amount + tax_amount + shipping_revenue, 2) AS total_amount
FROM priced AS po
INNER JOIN shop_raw_markets AS m
    ON po.market_id = m.market_id
