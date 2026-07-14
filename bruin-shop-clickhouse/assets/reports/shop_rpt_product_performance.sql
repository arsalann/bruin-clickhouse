/* @bruin
name: shop_rpt_product_performance
type: clickhouse.sql
materialization:
   type: table
depends:
    - shop_stg_products
    - shop_stg_orders

columns:
  - name: product_id
    type: varchar
    primary_key: true
    checks:
        - name: not_null
        - name: unique
  - name: product_name
    type: varchar
  - name: category
    type: varchar
  - name: sku
    type: varchar
  - name: list_price
    type: float
  - name: unit_cogs
    type: float
  - name: gross_margin_pct
    type: float
  - name: inventory_on_hand
    type: integer
  - name: order_attempts
    type: integer
  - name: successful_orders
    type: integer
  - name: refunded_orders
    type: integer
  - name: units_sold
    type: integer
  - name: net_revenue
    type: float
  - name: gross_profit
    type: float
  - name: contribution_profit
    type: float
  - name: refund_rate
    type: float
  - name: inventory_to_sales_ratio
    type: float
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
    FROM shop_stg_orders
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
FROM shop_stg_products AS p
LEFT JOIN orders AS o
    ON p.product_id = o.product_id
