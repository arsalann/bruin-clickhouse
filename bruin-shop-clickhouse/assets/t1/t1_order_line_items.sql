/* @bruin
name: bruin_shop.t1_order_line_items
type: clickhouse.sql
description: "Synthetic Shopify-style T1 order lines at one row per product line."
materialization:
  type: table
  strategy: time_interval
  incremental_key: order_date
  time_granularity: date
depends:
  - bruin_shop.t1_web_sessions
  - bruin_shop.t1_special_events
  - bruin_shop.t1_products
  - bruin_shop.t1_customers

tags:
  - t1
  - source
  - synthetic
domains:
  - commerce
meta:
  grain: one row per order line
  source_system: synthetic_shopify

custom_checks:
  - name: interval contains order lines
    description: Ensures every requested interval produces order-line rows.
    query: |
      SELECT count() > 0
      FROM bruin_shop.t1_order_line_items
      WHERE order_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
    value: 1
    blocking: true
  - name: customers exist before ordering
    description: Ensures no generated order line is assigned before customer signup.
    query: |
      SELECT l.line_item_id
      FROM bruin_shop.t1_order_line_items AS l
      INNER JOIN bruin_shop.t1_customers AS c
        ON l.customer_id = c.customer_id
      WHERE l.order_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
        AND l.order_date < c.signup_date
    count: 0
    blocking: true
  - name: products are launched before ordering
    description: Ensures no generated line uses a product before its catalog launch date.
    query: |
      SELECT l.line_item_id
      FROM bruin_shop.t1_order_line_items AS l
      INNER JOIN bruin_shop.t1_products AS p
        ON l.product_id = p.product_id
      WHERE l.order_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
        AND l.order_date < p.launch_date
    count: 0
    blocking: true
columns:
  - name: line_item_id
    type: UInt64
    description: "Stable time-ordered identifier of the order line."
    primary_key: true
    checks:
      - name: not_null
      - name: unique
  - name: order_id
    type: UInt64
    description: "Stable time-ordered identifier of the order attempt."
  - name: order_date
    type: Date
    description: "Calendar date on which the order was placed."
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
    description: "Campaign or operational scenario active for the order."
  - name: campaign_id
    type: LowCardinality(String)
    description: "Campaign or non-paid source identifier."
  - name: customer_id
    type: UInt64
    description: "Stable identifier of the customer."
  - name: line_number
    type: UInt8
    description: "One-based line position within the order."
    checks:
      - name: positive
  - name: product_id
    type: String
    description: "Stable identifier of the product."
  - name: product_name
    type: String
    description: "Display name of the product."
  - name: product_category
    type: LowCardinality(String)
    description: "Merchandise category of the product."
  - name: sku
    type: String
    description: "Stock-keeping unit of the product."
  - name: quantity
    type: UInt8
    description: "Units of the product on the order line."
    checks:
      - name: positive
  - name: unit_price
    type: Decimal(18, 2)
    description: "Catalog unit price in USD."
    checks:
      - name: positive
  - name: gross_merchandise_amount
    type: Decimal(18, 2)
    description: "Line value before discounts."
    checks:
      - name: non_negative
  - name: discount_amount
    type: Decimal(18, 2)
    description: "Discount allocated directly to the line."
    checks:
      - name: non_negative
  - name: net_merchandise_amount
    type: Decimal(18, 2)
    description: "Line merchandise value after discounts and before refunds."
    checks:
      - name: non_negative
  - name: unit_cogs
    type: Decimal(18, 2)
    description: "Standard unit cost in USD."
    checks:
      - name: non_negative
  - name: cogs_amount
    type: Decimal(18, 2)
    description: "Standard product cost for the line quantity."
    checks:
      - name: non_negative
@bruin */

WITH
    ['direct', 'email', 'organic', 'paid_search', 'paid_social'] AS channel_names,
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
            toUInt32(
                greatest(
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
                )
            ) AS order_count
        FROM bruin_shop.t1_web_sessions AS s
        LEFT JOIN bruin_shop.t1_special_events AS e
            ON s.event_id = e.event_id
        WHERE s.session_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
    ),
    orders AS (
        SELECT
            g.order_date,
            g.market_id,
            g.market_index,
            g.state,
            g.city,
            g.channel,
            g.event_id,
            g.campaign_id,
            toUInt64(dateDiff('day', toDate('2025-01-01'), g.order_date)) * 1000000
                + toUInt64(g.market_index) * 10000
                + toUInt64(indexOf(channel_names, g.channel)) * 1000
                + toUInt64(order_number)
                + 1 AS order_id
        FROM order_groups AS g
        ARRAY JOIN range(g.order_count) AS order_number
    ),
    customer_scored AS (
        SELECT
            *,
            least(
                toUInt64(10000),
                toUInt64(greatest(1, (dateDiff('day', toDate('2024-07-01'), order_date) + 1) * 14))
            ) AS available_customer_slots,
            cityHash64(toString(order_id), 'customer') AS customer_hash,
            cityHash64(toString(order_id), 'line_count') % 100 AS line_count_roll
        FROM orders
    ),
    shaped_orders AS (
        SELECT
            *,
            toUInt64(market_index) + 12 * (customer_hash % available_customer_slots) AS customer_id,
            toUInt8(multiIf(line_count_roll < 72, 1, line_count_roll < 94, 2, 3)) AS line_count
        FROM customer_scored
    ),
    exploded AS (
        SELECT
            *,
            toUInt8(line_index + 1) AS line_number,
            cityHash64(toString(order_id), toString(line_index), 'product') AS product_hash,
            cityHash64(toString(order_id), toString(line_index), 'quantity') AS quantity_hash
        FROM shaped_orders
        ARRAY JOIN range(toUInt32(line_count)) AS line_index
    ),
    selected AS (
        SELECT
            *,
            multiIf(
                event_id = 'trail_shoe_launch' AND channel = 'paid_social' AND line_number = 1 AND product_hash % 100 < 68,
                    'prod_shoes_04',
                order_date < toDate('2026-03-10'),
                    arrayElement(non_trail_shoe_products, toUInt32((product_hash % length(non_trail_shoe_products)) + 1)),
                event_id = 'trail_shoe_stockout' AND channel = 'paid_social',
                    arrayElement(non_trail_shoe_products, toUInt32((product_hash % length(non_trail_shoe_products)) + 1)),
                event_id = 'product_defect_black_tote' AND line_number = 1 AND product_hash % 100 < 72,
                    'prod_accessories_09',
                arrayElement(product_ids, toUInt32((product_hash % length(product_ids)) + 1))
            ) AS product_id,
            toUInt8(1 + (quantity_hash % 2)) AS quantity,
            multiIf(
                channel = 'email', toDecimal64(0.12, 4),
                channel IN ('paid_search', 'paid_social'), toDecimal64(0.08, 4),
                toDecimal64(0.02, 4)
            ) AS discount_rate
        FROM exploded
    ),
    priced AS (
        SELECT
            s.order_id AS order_id,
            s.order_date AS order_date,
            s.market_id AS market_id,
            s.market_index AS market_index,
            s.state AS state,
            s.city AS city,
            s.channel AS channel,
            s.event_id AS event_id,
            s.campaign_id AS campaign_id,
            s.customer_id AS customer_id,
            s.line_number AS line_number,
            s.product_id AS product_id,
            s.quantity AS quantity,
            s.discount_rate AS discount_rate,
            p.product_name AS product_name,
            p.category AS product_category,
            p.sku AS sku,
            p.list_price AS unit_price,
            p.unit_cogs AS unit_cogs,
            toDecimal64(p.list_price * s.quantity, 2) AS gross_merchandise_amount,
            toDecimal64(p.list_price * s.quantity * s.discount_rate, 2) AS discount_amount,
            toDecimal64(p.unit_cogs * s.quantity, 2) AS cogs_amount
        FROM selected AS s
        INNER JOIN bruin_shop.t1_products AS p
            ON s.product_id = p.product_id
    )
SELECT
    order_id * 10 + toUInt64(line_number) AS line_item_id,
    order_id,
    order_date,
    market_id,
    market_index,
    state,
    city,
    channel,
    event_id,
    campaign_id,
    customer_id,
    line_number,
    product_id,
    product_name,
    product_category,
    sku,
    quantity,
    unit_price,
    gross_merchandise_amount,
    discount_amount,
    toDecimal64(gross_merchandise_amount - discount_amount, 2) AS net_merchandise_amount,
    unit_cogs,
    cogs_amount
FROM priced
