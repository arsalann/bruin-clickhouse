/* @bruin
name: bruin_shop.t1_orders
type: clickhouse.sql
description: "Synthetic Shopify-style T1 order headers at one row per order attempt."
materialization:
  type: table
  strategy: time_interval
  incremental_key: order_date
  time_granularity: date
depends:
  - bruin_shop.t1_order_line_items
  - bruin_shop.t1_customers
  - bruin_shop.t1_markets

tags:
  - t1
  - source
  - synthetic
domains:
  - commerce
meta:
  grain: one row per order attempt
  source_system: synthetic_shopify

custom_checks:
  - name: interval contains orders
    description: Ensures every requested interval produces order headers.
    query: |
      SELECT count() > 0
      FROM bruin_shop.t1_orders
      WHERE order_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
    value: 1
    blocking: true
  - name: order totals reconcile
    description: Ensures subtotal, discounts, tax, and shipping reconcile to the order total.
    query: |
      SELECT order_id
      FROM bruin_shop.t1_orders
      WHERE order_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
        AND total_amount != gross_merchandise_amount - discount_amount + tax_amount + shipping_revenue
    count: 0
    blocking: true
columns:
  - name: order_id
    type: UInt64
    description: "Stable time-ordered identifier of the order attempt."
    primary_key: true
    checks:
      - name: not_null
      - name: unique
  - name: order_name
    type: String
    description: "Unique customer-facing order reference."
    checks:
      - name: not_null
      - name: unique
  - name: customer_id
    type: UInt64
    description: "Stable identifier of the customer."
  - name: customer_email
    type: String
    description: "Synthetic customer email address."
  - name: order_date
    type: Date
    description: "Calendar date on which the order was placed."
  - name: order_datetime
    type: DateTime('UTC')
    description: "Timestamp at which the order was placed in UTC."
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
  - name: line_item_count
    type: UInt8
    description: "Number of product lines on the order."
    checks:
      - name: positive
  - name: item_count
    type: UInt16
    description: "Total product units on the order."
    checks:
      - name: positive
  - name: order_status
    type: LowCardinality(String)
    description: "Synthetic lifecycle state of the order."
    checks:
      - name: accepted_values
        value: ["cancelled", "paid", "partially_refunded", "refunded"]
  - name: financial_status
    type: LowCardinality(String)
    description: "Shopify-style financial status."
    checks:
      - name: accepted_values
        value: ["paid", "partially_refunded", "refunded", "voided"]
  - name: fulfillment_status
    type: LowCardinality(String)
    description: "Shopify-style fulfillment status."
    checks:
      - name: accepted_values
        value: ["cancelled", "fulfilled", "unfulfilled"]
  - name: gross_merchandise_amount
    type: Decimal(18, 2)
    description: "Merchandise value before discounts."
    checks:
      - name: non_negative
  - name: discount_amount
    type: Decimal(18, 2)
    description: "Order-level sum of line discounts."
    checks:
      - name: non_negative
  - name: tax_amount
    type: Decimal(18, 2)
    description: "Simplified sales tax charged on the order."
    checks:
      - name: non_negative
  - name: shipping_revenue
    type: Decimal(18, 2)
    description: "Shipping amount charged to the customer."
    checks:
      - name: non_negative
  - name: shipping_cost
    type: Decimal(18, 2)
    description: "Modeled fulfillment cost for the order."
    checks:
      - name: non_negative
  - name: cogs_amount
    type: Decimal(18, 2)
    description: "Standard product cost across all order lines."
    checks:
      - name: non_negative
  - name: total_amount
    type: Decimal(18, 2)
    description: "Final amount presented for payment."
    checks:
      - name: non_negative
@bruin */

WITH
    line_rollup AS (
        SELECT
            order_id,
            order_date,
            market_id,
            state,
            city,
            channel,
            event_id,
            campaign_id,
            customer_id,
            toUInt8(count()) AS line_item_count,
            toUInt16(sum(quantity)) AS item_count,
            toDecimal64(sum(gross_merchandise_amount), 2) AS gross_merchandise_amount,
            toDecimal64(sum(discount_amount), 2) AS discount_amount,
            toDecimal64(sum(cogs_amount), 2) AS cogs_amount,
            max(toUInt8(product_id = 'prod_accessories_09')) AS has_black_tote
        FROM bruin_shop.t1_order_line_items
        WHERE order_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
        GROUP BY
            order_id,
            order_date,
            market_id,
            state,
            city,
            channel,
            event_id,
            campaign_id,
            customer_id
    ),
    scored AS (
        SELECT
            l.order_id AS order_id,
            l.order_date AS order_date,
            l.market_id AS market_id,
            l.state AS state,
            l.city AS city,
            l.channel AS channel,
            l.event_id AS event_id,
            l.campaign_id AS campaign_id,
            l.customer_id AS customer_id,
            l.line_item_count AS line_item_count,
            l.item_count AS item_count,
            l.gross_merchandise_amount AS gross_merchandise_amount,
            l.discount_amount AS discount_amount,
            l.cogs_amount AS cogs_amount,
            l.has_black_tote AS has_black_tote,
            c.customer_email AS customer_email,
            m.tax_rate AS tax_rate,
            cityHash64(toString(l.order_id), 'status') % 100 AS status_roll,
            cityHash64(toString(l.order_id), 'defect_status') % 100 AS defect_status_roll,
            cityHash64(toString(l.order_id), 'fulfillment') % 100 AS fulfillment_roll,
            cityHash64(toString(l.order_id), 'order_time') % 86400 AS seconds_after_midnight
        FROM line_rollup AS l
        INNER JOIN bruin_shop.t1_customers AS c
            ON l.customer_id = c.customer_id
        INNER JOIN bruin_shop.t1_markets AS m
            ON l.market_id = m.market_id
    ),
    statused AS (
        SELECT
            *,
            multiIf(
                event_id = 'product_defect_black_tote' AND has_black_tote = 1 AND defect_status_roll < 96,
                    'partially_refunded',
                status_roll < 2, 'cancelled',
                status_roll < 5, 'refunded',
                'paid'
            ) AS order_status
        FROM scored
    ),
    calculated AS (
        SELECT
            *,
            toDecimal64((gross_merchandise_amount - discount_amount) * tax_rate, 2) AS tax_amount,
            multiIf(
                gross_merchandise_amount - discount_amount >= toDecimal64(90, 2),
                toDecimal64(0, 2),
                toDecimal64(6.95, 2)
            ) AS shipping_revenue,
            toDecimal64(toDecimal64(item_count, 2) * toDecimal64(2.65, 2), 2) AS shipping_cost
        FROM statused
    )
SELECT
    order_id,
    concat('#', toString(1000001 + order_id)) AS order_name,
    customer_id,
    customer_email,
    order_date,
    toDateTime(order_date, 'UTC') + toIntervalSecond(toUInt32(seconds_after_midnight)) AS order_datetime,
    market_id,
    state,
    city,
    channel,
    event_id,
    campaign_id,
    line_item_count,
    item_count,
    toLowCardinality(order_status) AS order_status,
    toLowCardinality(
        multiIf(
            order_status = 'cancelled', 'voided',
            order_status = 'refunded', 'refunded',
            order_status = 'partially_refunded', 'partially_refunded',
            'paid'
        )
    ) AS financial_status,
    toLowCardinality(
        multiIf(
            order_status = 'cancelled', 'cancelled',
            fulfillment_roll < 10, 'unfulfilled',
            'fulfilled'
        )
    ) AS fulfillment_status,
    gross_merchandise_amount,
    discount_amount,
    tax_amount,
    shipping_revenue,
    shipping_cost,
    cogs_amount,
    toDecimal64(gross_merchandise_amount - discount_amount + tax_amount + shipping_revenue, 2) AS total_amount
FROM calculated
