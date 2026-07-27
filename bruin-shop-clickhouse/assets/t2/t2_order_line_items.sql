/* @bruin
name: bruin_shop.t2_order_line_items
type: clickhouse.sql
description: "Conformed T2 order lines with proportional refunds and product-level margin."
materialization:
  type: table
  strategy: time_interval
  incremental_key: order_date
  time_granularity: date
depends:
  - bruin_shop.t1_order_line_items
  - bruin_shop.t2_orders

tags:
  - t2
  - conformed
domains:
  - commerce
  - finance
meta:
  grain: one row per order line
  source_system: conformed_shopify_stripe

custom_checks:
  - name: interval contains conformed lines
    description: Ensures the requested interval contains standardized order-line rows.
    query: |
      SELECT count() > 0
      FROM bruin_shop.t2_order_line_items
      WHERE order_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
    value: 1
    blocking: true
  - name: line refunds reconcile to orders
    description: Ensures line-level refund allocation sums exactly to the order merchandise refund.
    query: |
      SELECT l.order_id
      FROM bruin_shop.t2_order_line_items AS l
      INNER JOIN bruin_shop.t2_orders AS o
        ON l.order_id = o.order_id
      WHERE l.order_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
      GROUP BY l.order_id, o.refunded_merchandise_amount
      HAVING sum(l.allocated_refund_amount) != o.refunded_merchandise_amount
    count: 0
    blocking: true
  - name: line economics reconcile
    description: Ensures each line's net merchandise and gross profit calculations balance.
    query: |
      SELECT line_item_id
      FROM bruin_shop.t2_order_line_items
      WHERE order_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
        AND (
          net_merchandise_revenue
            != if(
              is_successful_order = 1,
              line_net_merchandise_before_refund - allocated_refund_amount,
              toDecimal64(0, 2)
            )
          OR gross_profit != net_merchandise_revenue - recognized_cogs_amount
        )
    count: 0
    blocking: true

unit_tests:
  - name: allocates refund to a product line
    inputs:
      - asset: bruin_shop.t1_order_line_items
        rows:
          - {line_item_id: 11, order_id: 1, order_date: "2026-01-05", market_id: "NY-new-york", market_index: 3, state: "NY", city: "New York", channel: "paid_search", event_id: "none", campaign_id: "google_always_on", customer_id: 10, line_number: 1, product_id: "prod_a", product_name: "Product A", product_category: "tshirts", sku: "A", quantity: 1, unit_price: 100, gross_merchandise_amount: 100, discount_amount: 10, net_merchandise_amount: 90, unit_cogs: 42, cogs_amount: 42}
      - asset: bruin_shop.t2_orders
        rows:
          - {order_id: 1, order_status: "partially_refunded", financial_status: "partially_refunded", fulfillment_status: "fulfilled", is_successful_order: 1, is_cancelled_order: 0, has_refund: 1, net_merchandise_before_refund: 90, refunded_merchandise_amount: 27}
    expected:
      count: 1
      rows:
        - {line_item_id: 11, allocated_refund_amount: 27, net_merchandise_revenue: 63, recognized_cogs_amount: 29.40, gross_profit: 33.60}

columns:
  - name: line_item_id
    type: UInt64
    description: "Stable identifier of the order line."
    primary_key: true
    checks:
      - name: not_null
      - name: unique
  - name: order_id
    type: UInt64
    description: "Stable identifier of the order attempt."
  - name: order_date
    type: Date
    description: "Calendar date on which the order was placed."
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
    description: "Normalized acquisition channel."
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
    description: "Units on the order line."
    checks:
      - name: positive
  - name: unit_price
    type: Decimal(18, 2)
    description: "Catalog unit price in USD."
    checks:
      - name: positive
  - name: gross_merchandise_amount
    type: Decimal(18, 2)
    description: "Line merchandise value before discounts."
    checks:
      - name: non_negative
  - name: discount_amount
    type: Decimal(18, 2)
    description: "Discount allocated directly to the line."
    checks:
      - name: non_negative
  - name: line_net_merchandise_before_refund
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
    description: "Standard product cost before refund treatment."
    checks:
      - name: non_negative
  - name: order_status
    type: LowCardinality(String)
    description: "Lifecycle state of the parent order."
  - name: financial_status
    type: LowCardinality(String)
    description: "Financial state of the parent order."
  - name: fulfillment_status
    type: LowCardinality(String)
    description: "Fulfillment state of the parent order."
  - name: is_successful_order
    type: UInt8
    description: "Whether payment was captured and the parent order was not cancelled."
  - name: is_cancelled_order
    type: UInt8
    description: "Whether the parent order was cancelled."
  - name: has_refund
    type: UInt8
    description: "Whether the parent order has a refund."
  - name: allocated_refund_amount
    type: Decimal(18, 2)
    description: "Order merchandise refund allocated proportionally to this line."
    checks:
      - name: non_negative
  - name: net_merchandise_revenue
    type: Decimal(18, 2)
    description: "Line merchandise value after discounts and allocated refunds."
    checks:
      - name: non_negative
  - name: recognized_cogs_amount
    type: Decimal(18, 2)
    description: "Product cost retained after cancellation and refund treatment."
    checks:
      - name: non_negative
  - name: gross_profit
    type: Decimal(18, 2)
    description: "Net merchandise revenue less recognized product cost."
@bruin */

WITH
    weighted AS (
        SELECT
            l.line_item_id AS line_item_id,
            l.order_id AS order_id,
            l.order_date AS order_date,
            l.market_id AS market_id,
            l.market_index AS market_index,
            l.state AS state,
            l.city AS city,
            l.channel AS channel,
            l.event_id AS event_id,
            l.campaign_id AS campaign_id,
            l.customer_id AS customer_id,
            l.line_number AS line_number,
            l.product_id AS product_id,
            l.product_name AS product_name,
            l.product_category AS product_category,
            l.sku AS sku,
            l.quantity AS quantity,
            l.unit_price AS unit_price,
            l.gross_merchandise_amount AS gross_merchandise_amount,
            l.discount_amount AS discount_amount,
            l.net_merchandise_amount AS net_merchandise_amount,
            l.unit_cogs AS unit_cogs,
            l.cogs_amount AS cogs_amount,
            o.order_status AS order_status,
            o.financial_status AS financial_status,
            o.fulfillment_status AS fulfillment_status,
            o.is_successful_order AS is_successful_order,
            o.is_cancelled_order AS is_cancelled_order,
            o.has_refund AS has_refund,
            o.refunded_merchandise_amount AS refunded_merchandise_amount,
            toInt64(o.refunded_merchandise_amount * 100) AS refund_cents,
            toInt64(o.net_merchandise_before_refund * 100) AS order_merchandise_cents,
            sum(toInt64(l.net_merchandise_amount * 100)) OVER (
                PARTITION BY l.order_id
                ORDER BY l.line_number
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            ) AS cumulative_line_cents,
            sum(toInt64(l.net_merchandise_amount * 100)) OVER (
                PARTITION BY l.order_id
                ORDER BY l.line_number
                ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
            ) AS prior_cumulative_line_cents
        FROM bruin_shop.t1_order_line_items AS l
        INNER JOIN bruin_shop.t2_orders AS o
            ON l.order_id = o.order_id
        WHERE l.order_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
    ),
    allocated AS (
        SELECT
            *,
            toDecimal64(
                toDecimal64(
                    if(
                        is_successful_order = 1 AND order_merchandise_cents > 0,
                        intDiv(refund_cents * cumulative_line_cents, order_merchandise_cents)
                            - intDiv(refund_cents * prior_cumulative_line_cents, order_merchandise_cents),
                        0
                    ),
                    2
                ) / toDecimal64(100, 2),
                2
            ) AS allocated_refund_amount
        FROM weighted
    ),
    netted AS (
        SELECT
            *,
            toDecimal64(
                if(
                    is_successful_order = 1,
                    net_merchandise_amount - allocated_refund_amount,
                    toDecimal64(0, 2)
                ),
                2
            ) AS net_merchandise_revenue
        FROM allocated
    ),
    costed AS (
        SELECT
            *,
            toDecimal64(
                if(
                    is_successful_order = 1 AND net_merchandise_amount > 0,
                    toFloat64(cogs_amount)
                        * toFloat64(net_merchandise_revenue)
                        / toFloat64(net_merchandise_amount),
                    0
                ),
                2
            ) AS recognized_cogs_amount
        FROM netted
    )
SELECT
    line_item_id,
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
    net_merchandise_amount AS line_net_merchandise_before_refund,
    unit_cogs,
    cogs_amount,
    order_status,
    financial_status,
    fulfillment_status,
    is_successful_order,
    is_cancelled_order,
    has_refund,
    allocated_refund_amount,
    net_merchandise_revenue,
    recognized_cogs_amount,
    toDecimal64(net_merchandise_revenue - recognized_cogs_amount, 2) AS gross_profit
FROM costed
