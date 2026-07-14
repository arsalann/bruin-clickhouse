/* @bruin
name: shop_rpt_daily_revenue
type: clickhouse.sql
materialization:
   type: table
depends:
    - shop_stg_orders

columns:
  - name: revenue_date
    type: date
    primary_key: true
    checks:
        - name: not_null
        - name: unique
  - name: order_attempts
    type: integer
  - name: successful_orders
    type: integer
  - name: cancelled_orders
    type: integer
  - name: refunded_orders
    type: integer
  - name: items_sold
    type: integer
  - name: gross_merchandise_amount
    type: float
  - name: discount_amount
    type: float
  - name: refund_amount
    type: float
  - name: net_revenue
    type: float
  - name: cogs_amount
    type: float
  - name: shipping_revenue
    type: float
  - name: shipping_cost
    type: float
  - name: gross_profit
    type: float
  - name: contribution_profit
    type: float
  - name: average_order_value
    type: float
@bruin */

SELECT
    order_date AS revenue_date,
    count() AS order_attempts,
    countIf(is_successful_order = 1) AS successful_orders,
    countIf(is_cancelled_order = 1) AS cancelled_orders,
    countIf(has_refund = 1) AS refunded_orders,
    sum(item_count) AS items_sold,
    round(sum(gross_merchandise_amount), 2) AS gross_merchandise_amount,
    round(sum(discount_amount), 2) AS discount_amount,
    round(sum(refund_amount), 2) AS refund_amount,
    round(sum(net_revenue), 2) AS net_revenue,
    round(sum(cogs_amount), 2) AS cogs_amount,
    round(sum(shipping_revenue), 2) AS shipping_revenue,
    round(sum(shipping_cost), 2) AS shipping_cost,
    round(sum(gross_profit), 2) AS gross_profit,
    round(sum(contribution_profit), 2) AS contribution_profit,
    round(if(successful_orders = 0, 0, net_revenue / successful_orders), 2) AS average_order_value
FROM shop_stg_orders
GROUP BY order_date
