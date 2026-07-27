/* @bruin
name: bruin_shop.t3_product_performance
type: clickhouse.sql
description: "T3 product mart with line-level sales, refunds, gross profit, and inventory context."
materialization:
  type: table
  strategy: create+replace
depends:
  - bruin_shop.t2_products
  - bruin_shop.t2_order_line_items

tags:
  - t3
  - mart
domains:
  - commerce
  - finance
meta:
  grain: one row per product

custom_checks:
  - name: preserves the product catalog
    description: Ensures products with no sales remain visible in the mart.
    query: |
      SELECT
        (SELECT count() FROM bruin_shop.t3_product_performance)
        =
        (SELECT count() FROM bruin_shop.t2_products)
    value: 1
    blocking: true
  - name: product economics reconcile
    description: Ensures product gross profit balances to net merchandise revenue less recognized cost.
    query: |
      SELECT product_id
      FROM bruin_shop.t3_product_performance
      WHERE gross_profit != net_merchandise_revenue - recognized_cogs_amount
    count: 0
    blocking: true

columns:
  - name: product_id
    type: String
    description: "Stable identifier of the product."
    primary_key: true
    checks:
      - name: not_null
      - name: unique
  - name: product_name
    type: String
    description: "Display name of the product."
  - name: category
    type: LowCardinality(String)
    description: "Merchandise category assigned to the product."
  - name: sku
    type: String
    description: "Stock-keeping unit assigned to the product."
  - name: list_price
    type: Decimal(18, 2)
    description: "Catalog unit price in USD."
  - name: unit_cogs
    type: Decimal(18, 2)
    description: "Standard unit cost in USD."
  - name: catalog_gross_margin_pct
    type: Float64
    description: "Catalog unit margin divided by list price."
  - name: inventory_on_hand
    type: UInt32
    description: "Current synthetic sellable inventory units."
  - name: order_attempts
    type: UInt64
    description: "Distinct order attempts containing the product."
  - name: successful_orders
    type: UInt64
    description: "Distinct successfully captured orders containing the product."
  - name: refunded_orders
    type: UInt64
    description: "Distinct refunded orders containing the product."
  - name: units_purchased
    type: UInt64
    description: "Units on successfully captured orders."
  - name: gross_merchandise_amount
    type: Decimal(18, 2)
    description: "Merchandise value before discounts on successfully captured lines."
  - name: discount_amount
    type: Decimal(18, 2)
    description: "Discounts on successfully captured lines."
  - name: allocated_refund_amount
    type: Decimal(18, 2)
    description: "Order merchandise refunds allocated to the product's lines."
  - name: net_merchandise_revenue
    type: Decimal(18, 2)
    description: "Line merchandise revenue after discounts and allocated refunds."
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
  - name: realized_gross_margin_pct
    type: Float64
    description: "Realized gross profit divided by net merchandise revenue."
  - name: refund_rate
    type: Float64
    description: "Refunded product orders divided by successfully captured product orders."
    checks:
      - name: min
        value: 0
      - name: max
        value: 1
  - name: inventory_to_units_purchased_ratio
    type: Float64
    description: "Current inventory divided by historical purchased units."
    checks:
      - name: non_negative
@bruin */

WITH line_metrics AS (
    SELECT
        product_id,
        uniqExact(order_id) AS order_attempts,
        uniqExactIf(order_id, is_successful_order = 1) AS successful_orders,
        uniqExactIf(order_id, has_refund = 1) AS refunded_orders,
        sumIf(toUInt64(quantity), is_successful_order = 1) AS units_purchased,
        toDecimal64(sumIf(gross_merchandise_amount, is_successful_order = 1), 2) AS gross_merchandise_amount,
        toDecimal64(sumIf(discount_amount, is_successful_order = 1), 2) AS discount_amount,
        toDecimal64(sum(allocated_refund_amount), 2) AS allocated_refund_amount,
        toDecimal64(sum(net_merchandise_revenue), 2) AS net_merchandise_revenue,
        toDecimal64(sum(recognized_cogs_amount), 2) AS recognized_cogs_amount,
        toDecimal64(sum(gross_profit), 2) AS gross_profit
    FROM bruin_shop.t2_order_line_items
    GROUP BY product_id
)
SELECT
    p.product_id AS product_id,
    p.product_name AS product_name,
    p.category AS category,
    p.sku AS sku,
    p.list_price AS list_price,
    p.unit_cogs AS unit_cogs,
    p.gross_margin_pct AS catalog_gross_margin_pct,
    p.inventory_on_hand AS inventory_on_hand,
    ifNull(l.order_attempts, toUInt64(0)) AS order_attempts,
    ifNull(l.successful_orders, toUInt64(0)) AS successful_orders,
    ifNull(l.refunded_orders, toUInt64(0)) AS refunded_orders,
    ifNull(l.units_purchased, toUInt64(0)) AS units_purchased,
    ifNull(l.gross_merchandise_amount, toDecimal64(0, 2)) AS gross_merchandise_amount,
    ifNull(l.discount_amount, toDecimal64(0, 2)) AS discount_amount,
    ifNull(l.allocated_refund_amount, toDecimal64(0, 2)) AS allocated_refund_amount,
    ifNull(l.net_merchandise_revenue, toDecimal64(0, 2)) AS net_merchandise_revenue,
    ifNull(l.recognized_cogs_amount, toDecimal64(0, 2)) AS recognized_cogs_amount,
    ifNull(l.gross_profit, toDecimal64(0, 2)) AS gross_profit,
    round(
        if(net_merchandise_revenue = 0, 0, toFloat64(gross_profit) / toFloat64(net_merchandise_revenue)),
        4
    ) AS realized_gross_margin_pct,
    round(
        if(successful_orders = 0, 0, toFloat64(refunded_orders) / toFloat64(successful_orders)),
        4
    ) AS refund_rate,
    round(
        if(units_purchased = 0, 0, toFloat64(p.inventory_on_hand) / toFloat64(units_purchased)),
        4
    ) AS inventory_to_units_purchased_ratio
FROM bruin_shop.t2_products AS p
LEFT JOIN line_metrics AS l
    ON p.product_id = l.product_id
