/* @bruin
name: bruin_shop.t3_product_performance
type: clickhouse.sql
description: "T3 product-performance mart with sales, refund, margin, and inventory metrics."
materialization:
   type: table
   strategy: truncate+insert
depends:
    - bruin_shop.t2_products
    - bruin_shop.t2_orders

custom_checks:
  - name: contains rows
    description: Ensures the materialized table is not empty.
    query: SELECT count() > 0 FROM bruin_shop.t3_product_performance
    value: 1
    blocking: true
columns:
  - name: product_id
    type: varchar
    description: "Stable identifier of the product."
    primary_key: true
    checks:
        - name: not_null
        - name: unique
  - name: product_name
    type: varchar
    description: "Display name of the product."
  - name: category
    type: varchar
    description: "Merchandise category assigned to the product."
  - name: sku
    type: varchar
    description: "Stock-keeping unit assigned to the product."
  - name: list_price
    type: float
    description: "Catalog list price per product unit."
    checks:
      - name: positive
  - name: unit_cogs
    type: float
    description: "Cost of goods sold per product unit."
    checks:
      - name: non_negative
  - name: gross_margin_pct
    type: float
    description: "Gross profit as a percentage of net revenue."
  - name: inventory_on_hand
    type: integer
    description: "Current sellable units available in inventory."
    checks:
      - name: non_negative
  - name: order_attempts
    type: integer
    description: "Number of order attempts in the period."
    checks:
      - name: non_negative
  - name: successful_orders
    type: integer
    description: "Number of successfully paid orders."
    checks:
      - name: non_negative
  - name: refunded_orders
    type: integer
    description: "Number of refunded order attempts."
    checks:
      - name: non_negative
  - name: units_sold
    type: integer
    description: "Number of product units sold."
    checks:
      - name: non_negative
  - name: net_revenue
    type: float
    description: "Revenue after discounts, refunds, and applicable adjustments."
    checks:
      - name: non_negative
  - name: gross_profit
    type: float
    description: "Net revenue less cost of goods sold and shipping cost."
  - name: contribution_profit
    type: float
    description: "Net revenue less variable marketing, fulfilment, and product costs."
  - name: refund_rate
    type: float
    description: "Refunded orders divided by successful orders."
    checks:
      - name: min
        value: 0
      - name: max
        value: 1
  - name: inventory_to_sales_ratio
    type: float
    description: "Inventory quantity relative to units sold."
@bruin */

WITH orders AS (
    SELECT
        product_id,
        count() AS order_attempts,
        countIf(is_successful_order = 1) AS successful_orders,
        countIf(has_refund = 1) AS refunded_orders,
        sum(item_count) AS units_sold,
        round(sum(net_revenue), 2) AS net_revenue,
        round(sum(gross_profit), 2) AS gross_profit,
        round(sum(contribution_profit), 2) AS contribution_profit
    FROM bruin_shop.t2_orders
    GROUP BY product_id
)
SELECT
    p.product_id AS product_id,
    p.product_name AS product_name,
    p.category AS category,
    p.sku AS sku,
    p.list_price AS list_price,
    p.unit_cogs AS unit_cogs,
    p.gross_margin_pct AS gross_margin_pct,
    p.inventory_on_hand AS inventory_on_hand,
    ifNull(o.order_attempts, 0) AS order_attempts,
    ifNull(o.successful_orders, 0) AS successful_orders,
    ifNull(o.refunded_orders, 0) AS refunded_orders,
    ifNull(o.units_sold, 0) AS units_sold,
    ifNull(o.net_revenue, 0.00) AS net_revenue,
    ifNull(o.gross_profit, 0.00) AS gross_profit,
    ifNull(o.contribution_profit, 0.00) AS contribution_profit,
    round(if(order_attempts = 0, 0, refunded_orders / order_attempts), 4) AS refund_rate,
    round(if(units_sold = 0, 0, inventory_on_hand / units_sold), 2) AS inventory_to_sales_ratio
FROM bruin_shop.t2_products AS p
LEFT JOIN orders AS o
    ON p.product_id = o.product_id
