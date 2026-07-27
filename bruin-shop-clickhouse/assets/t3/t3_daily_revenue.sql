/* @bruin
name: bruin_shop.t3_daily_revenue
type: clickhouse.sql
description: "T3 daily commerce mart covering orders, refunds, revenue, and contribution economics."
materialization:
  type: table
  strategy: time_interval
  incremental_key: revenue_date
  time_granularity: date
depends:
  - bruin_shop.t2_orders

tags:
  - t3
  - mart
domains:
  - commerce
  - finance
meta:
  grain: one row per calendar date

custom_checks:
  - name: interval contains daily revenue
    description: Ensures the requested interval contains daily commerce rows.
    query: |
      SELECT count() > 0
      FROM bruin_shop.t3_daily_revenue
      WHERE revenue_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
    value: 1
    blocking: true
  - name: daily order and margin arithmetic reconciles
    description: Ensures order states and contribution economics balance at daily grain.
    query: |
      SELECT revenue_date
      FROM bruin_shop.t3_daily_revenue
      WHERE revenue_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
        AND (
          order_attempts != successful_orders + cancelled_orders
          OR gross_profit != net_revenue - recognized_cogs_amount
          OR contribution_margin != gross_profit - recognized_shipping_cost - payment_fee_amount
        )
    count: 0
    blocking: true

unit_tests:
  - name: aggregates successful order economics
    inputs:
      - asset: bruin_shop.t2_orders
        rows:
          - {order_id: 1, order_date: "2026-01-05", item_count: 2, is_successful_order: 1, is_cancelled_order: 0, has_refund: 1, gross_merchandise_amount: 100, discount_amount: 10, refund_amount: 20, net_revenue: 80, recognized_cogs_amount: 30, recognized_shipping_cost: 5, payment_fee_amount: 3, gross_profit: 50, contribution_margin: 42}
    expected:
      count: 1
      rows:
        - {order_attempts: 1, successful_orders: 1, cancelled_orders: 0, refunded_orders: 1, items_purchased: 2, net_revenue: 80, contribution_margin: 42, average_order_value: 80}

columns:
  - name: revenue_date
    type: Date
    description: "Calendar date represented by the revenue row."
    primary_key: true
    checks:
      - name: not_null
      - name: unique
  - name: order_attempts
    type: UInt64
    description: "Number of all order attempts."
    checks:
      - name: non_negative
  - name: successful_orders
    type: UInt64
    description: "Number of successfully captured orders, including later refunds."
    checks:
      - name: non_negative
  - name: cancelled_orders
    type: UInt64
    description: "Number of cancelled order attempts."
    checks:
      - name: non_negative
  - name: refunded_orders
    type: UInt64
    description: "Number of orders with a refund record."
    checks:
      - name: non_negative
  - name: items_purchased
    type: UInt64
    description: "Units on successfully captured orders."
    checks:
      - name: non_negative
  - name: gross_merchandise_amount
    type: Decimal(18, 2)
    description: "Merchandise value before discounts on successfully captured orders."
    checks:
      - name: non_negative
  - name: discount_amount
    type: Decimal(18, 2)
    description: "Discounts on successfully captured orders."
    checks:
      - name: non_negative
  - name: refund_amount
    type: Decimal(18, 2)
    description: "Amount returned to customers."
    checks:
      - name: non_negative
  - name: net_revenue
    type: Decimal(18, 2)
    description: "Captured order totals net of refunds."
    checks:
      - name: non_negative
  - name: recognized_cogs_amount
    type: Decimal(18, 2)
    description: "Product cost retained after cancellation and refund treatment."
    checks:
      - name: non_negative
  - name: recognized_shipping_cost
    type: Decimal(18, 2)
    description: "Fulfillment cost on successfully captured orders."
    checks:
      - name: non_negative
  - name: payment_fee_amount
    type: Decimal(18, 2)
    description: "Payment-processing fees on the day's order attempts."
    checks:
      - name: non_negative
  - name: gross_profit
    type: Decimal(18, 2)
    description: "Net revenue less recognized product cost."
  - name: contribution_margin
    type: Decimal(18, 2)
    description: "Gross profit less fulfillment and payment-processing costs, before media spend."
  - name: average_order_value
    type: Decimal(18, 2)
    description: "Net revenue divided by successfully captured orders."
    checks:
      - name: non_negative
  - name: refund_rate
    type: Float64
    description: "Orders with refunds divided by successfully captured orders."
    checks:
      - name: min
        value: 0
      - name: max
        value: 1
@bruin */

SELECT
    order_date AS revenue_date,
    count() AS order_attempts,
    countIf(is_successful_order = 1) AS successful_orders,
    countIf(is_cancelled_order = 1) AS cancelled_orders,
    countIf(has_refund = 1) AS refunded_orders,
    sumIf(toUInt64(item_count), is_successful_order = 1) AS items_purchased,
    toDecimal64(sumIf(gross_merchandise_amount, is_successful_order = 1), 2) AS gross_merchandise_amount,
    toDecimal64(sumIf(discount_amount, is_successful_order = 1), 2) AS discount_amount,
    toDecimal64(sum(refund_amount), 2) AS refund_amount,
    toDecimal64(sum(net_revenue), 2) AS net_revenue,
    toDecimal64(sum(recognized_cogs_amount), 2) AS recognized_cogs_amount,
    toDecimal64(sum(recognized_shipping_cost), 2) AS recognized_shipping_cost,
    toDecimal64(sum(payment_fee_amount), 2) AS payment_fee_amount,
    toDecimal64(sum(gross_profit), 2) AS gross_profit,
    toDecimal64(sum(contribution_margin), 2) AS contribution_margin,
    toDecimal64(
        if(successful_orders = 0, 0, toFloat64(net_revenue) / toFloat64(successful_orders)),
        2
    ) AS average_order_value,
    round(
        if(successful_orders = 0, 0, toFloat64(refunded_orders) / toFloat64(successful_orders)),
        4
    ) AS refund_rate
FROM bruin_shop.t2_orders
WHERE order_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
GROUP BY order_date
