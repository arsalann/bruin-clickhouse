/* @bruin
name: bruin_shop.t3_daily_revenue
type: clickhouse.sql
description: "T3 daily revenue mart covering order, refund, cost, and profitability measures."
materialization:
   type: table
   strategy: append
depends:
    - bruin_shop.t2_orders
    - bruin_shop.t3_daily_revenue_delete_interval

custom_checks:
  - name: contains rows
    description: Ensures the materialized table is not empty.
    query: SELECT count() > 0 FROM bruin_shop.t3_daily_revenue
    value: 1
    blocking: true
columns:
  - name: revenue_date
    type: date
    description: "Calendar date represented by the revenue row."
    primary_key: true
    checks:
        - name: not_null
        - name: unique
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
  - name: cancelled_orders
    type: integer
    description: "Number of cancelled order attempts."
  - name: refunded_orders
    type: integer
    description: "Number of refunded order attempts."
    checks:
      - name: non_negative
  - name: items_sold
    type: integer
    description: "Total units sold in the period."
    checks:
      - name: non_negative
  - name: gross_merchandise_amount
    type: float
    description: "Pre-discount merchandise value of the order."
  - name: discount_amount
    type: float
    description: "Discount value applied to the order."
    checks:
      - name: non_negative
  - name: refund_amount
    type: float
    description: "Monetary value refunded to the customer."
    checks:
      - name: non_negative
  - name: net_revenue
    type: float
    description: "Revenue after discounts, refunds, and applicable adjustments."
    checks:
      - name: non_negative
  - name: cogs_amount
    type: float
    description: "Cost of goods sold associated with the order or period."
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
  - name: gross_profit
    type: float
    description: "Net revenue less cost of goods sold and shipping cost."
  - name: contribution_profit
    type: float
    description: "Net revenue less variable marketing, fulfilment, and product costs."
  - name: average_order_value
    type: float
    description: "Average net revenue per successful order."
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
FROM bruin_shop.t2_orders
WHERE order_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
GROUP BY order_date
SETTINGS insert_deduplicate = 0
