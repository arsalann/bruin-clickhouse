/* @bruin
name: bruin_shop.t1_orders
type: clickhouse.sql
description: "T1 deterministic ecommerce order attempts with product, customer, and financial detail."
materialization:
   type: table
   strategy: append
depends:
    - bruin_shop.t1_web_sessions
    - bruin_shop.t1_special_events
    - bruin_shop.t1_products
    - bruin_shop.t1_customers
    - bruin_shop.t1_markets
    - bruin_shop.t1_orders_delete_interval

custom_checks:
  - name: contains rows
    description: Ensures the materialized table is not empty.
    query: SELECT count() > 0 FROM bruin_shop.t1_orders
    value: 1
    blocking: true
columns:
  - name: order_id
    type: integer
    description: "Stable identifier of the order attempt."
    primary_key: true
    checks:
        - name: not_null
        - name: unique
  - name: order_name
    type: varchar
    description: "Customer-facing order reference."
  - name: customer_id
    type: integer
    description: "Stable identifier of the customer."
  - name: customer_email
    type: varchar
    description: "Email address associated with the customer or order."
  - name: order_date
    type: date
    description: "Calendar date on which the order was placed."
  - name: order_datetime
    type: datetime
    description: "Timestamp at which the order was placed."
  - name: market_id
    type: varchar
    description: "Identifier of the market."
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
  - name: product_id
    type: varchar
    description: "Stable identifier of the product."
  - name: product_name
    type: varchar
    description: "Display name of the product."
  - name: product_category
    type: varchar
    description: "Merchandise category of the ordered product."
  - name: item_count
    type: integer
    description: "Number of units included in the order."
    checks:
      - name: positive
  - name: order_status
    type: varchar
    description: "Lifecycle status assigned to the order attempt."
    checks:
      - name: accepted_values
        value: ["cancelled", "paid", "partially_refunded", "refunded"]
  - name: financial_status
    type: varchar
    description: "Payment and refund state assigned to the order."
    checks:
      - name: accepted_values
        value: ["paid", "refunded", "voided"]
  - name: fulfillment_status
    type: varchar
    description: "Fulfilment state assigned to the order."
    checks:
      - name: accepted_values
        value: ["cancelled", "fulfilled", "unfulfilled"]
  - name: gross_merchandise_amount
    type: float
    description: "Pre-discount merchandise value of the order."
  - name: discount_amount
    type: float
    description: "Discount value applied to the order."
    checks:
      - name: non_negative
  - name: tax_amount
    type: float
    description: "Tax charged on the order or period."
    checks:
      - name: non_negative
  - name: shipping_revenue
    type: float
    description: "Shipping revenue charged on the order or period."
    checks:
      - name: non_negative
  - name: shipping_cost
    type: float
    description: "Shipping cost incurred for the order or period."
    checks:
      - name: non_negative
  - name: cogs_amount
    type: float
    description: "Cost of goods sold associated with the order or period."
    checks:
      - name: non_negative
  - name: total_amount
    type: float
    description: "Final amount charged for the order."
    checks:
      - name: non_negative
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
        FROM bruin_shop.t1_web_sessions AS s
        LEFT JOIN bruin_shop.t1_special_events AS e
            ON s.event_id = e.event_id
        WHERE s.session_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
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
        INNER JOIN bruin_shop.t1_products AS p
            ON s.product_id = p.product_id
        INNER JOIN bruin_shop.t1_customers AS c
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
INNER JOIN bruin_shop.t1_markets AS m
    ON po.market_id = m.market_id
SETTINGS insert_deduplicate = 0
