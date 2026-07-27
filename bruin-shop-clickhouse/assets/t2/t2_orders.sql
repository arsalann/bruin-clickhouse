/* @bruin
name: bruin_shop.t2_orders
type: clickhouse.sql
description: "Conformed T2 order headers with payment, refund, and unit-economics measures."
materialization:
  type: table
  strategy: time_interval
  incremental_key: order_date
  time_granularity: date
depends:
  - bruin_shop.t1_orders
  - bruin_shop.t1_payment_intents
  - bruin_shop.t1_refunds

tags:
  - t2
  - conformed
domains:
  - commerce
  - finance
meta:
  grain: one row per order attempt
  source_system: conformed_shopify_stripe

custom_checks:
  - name: interval contains conformed orders
    description: Ensures the requested interval contains standardized order rows.
    query: |
      SELECT count() > 0
      FROM bruin_shop.t2_orders
      WHERE order_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
    value: 1
    blocking: true
  - name: payment state reconciles
    description: Ensures every order has one matching payment with the expected state and amount.
    query: |
      SELECT order_id
      FROM bruin_shop.t2_orders
      WHERE order_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
        AND (
          payment_intent_id = ''
          OR payment_amount != total_amount
          OR payment_status != if(order_status = 'cancelled', 'canceled', 'succeeded')
        )
    count: 0
    blocking: true
  - name: refund and economics reconcile
    description: Ensures refunds are bounded and the order economics add up exactly to cents.
    query: |
      SELECT order_id
      FROM bruin_shop.t2_orders
      WHERE order_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
        AND (
          refund_amount > payment_amount
          OR has_refund != toUInt8(refund_amount > 0)
          OR gross_profit != net_revenue - recognized_cogs_amount
          OR contribution_margin != gross_profit - recognized_shipping_cost - payment_fee_amount
        )
    count: 0
    blocking: true

unit_tests:
  - name: allocates a partial refund through unit economics
    inputs:
      - asset: bruin_shop.t1_orders
        rows:
          - {order_id: 1, order_name: "#1000002", customer_id: 10, customer_email: "buyer@example.test", order_date: "2026-01-05", order_datetime: "2026-01-05 10:00:00", market_id: "NY-new-york", state: "NY", city: "New York", channel: "paid_search", event_id: "none", campaign_id: "google_always_on", line_item_count: 2, item_count: 2, order_status: "partially_refunded", financial_status: "partially_refunded", fulfillment_status: "fulfilled", gross_merchandise_amount: 100, discount_amount: 10, tax_amount: 9, shipping_revenue: 5, shipping_cost: 7, cogs_amount: 40, total_amount: 104}
      - asset: bruin_shop.t1_payment_intents
        rows:
          - {payment_intent_id: "pi_1", order_id: 1, amount: 104, status: "succeeded", payment_method: "card", payment_fee_amount: 3.32}
      - asset: bruin_shop.t1_refunds
        rows:
          - {refund_id: "re_1", payment_intent_id: "pi_1", order_id: 1, refund_amount: 26, refund_reason: "goodwill_partial_refund"}
    expected:
      count: 1
      rows:
        - {order_id: 1, is_successful_order: 1, has_refund: 1, refunded_merchandise_amount: 26, net_revenue: 78, recognized_cogs_amount: 28.44, gross_profit: 49.56, contribution_margin: 39.24}

columns:
  - name: order_id
    type: UInt64
    description: "Stable identifier of the order attempt."
    primary_key: true
    checks:
      - name: not_null
      - name: unique
  - name: order_name
    type: String
    description: "Unique customer-facing order reference."
    checks:
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
  - name: order_month
    type: Date
    description: "First day of the order month."
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
    description: "Lifecycle state of the order attempt."
    checks:
      - name: accepted_values
        value: ["cancelled", "paid", "partially_refunded", "refunded"]
  - name: financial_status
    type: LowCardinality(String)
    description: "Shopify-style financial status."
  - name: fulfillment_status
    type: LowCardinality(String)
    description: "Shopify-style fulfillment status."
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
  - name: net_merchandise_before_refund
    type: Decimal(18, 2)
    description: "Merchandise value after discounts and before refunds."
    checks:
      - name: non_negative
  - name: tax_amount
    type: Decimal(18, 2)
    description: "Sales tax charged on the order."
    checks:
      - name: non_negative
  - name: shipping_revenue
    type: Decimal(18, 2)
    description: "Shipping amount charged to the customer."
    checks:
      - name: non_negative
  - name: shipping_cost
    type: Decimal(18, 2)
    description: "Modeled fulfillment cost before cancellation treatment."
    checks:
      - name: non_negative
  - name: cogs_amount
    type: Decimal(18, 2)
    description: "Standard product cost before refund treatment."
    checks:
      - name: non_negative
  - name: total_amount
    type: Decimal(18, 2)
    description: "Final amount presented for payment."
    checks:
      - name: non_negative
  - name: payment_intent_id
    type: String
    description: "Stable Stripe-style payment-intent identifier."
  - name: payment_amount
    type: Decimal(18, 2)
    description: "Amount presented to the payment processor."
    checks:
      - name: non_negative
  - name: payment_status
    type: LowCardinality(String)
    description: "Resolved payment-intent status."
    checks:
      - name: accepted_values
        value: ["canceled", "succeeded"]
  - name: payment_method
    type: LowCardinality(String)
    description: "Payment method used for the intent."
  - name: payment_fee_amount
    type: Decimal(18, 2)
    description: "Modeled payment-processing fee."
    checks:
      - name: non_negative
  - name: refund_id
    type: String
    description: "Stable refund identifier, or an empty string."
  - name: refund_amount
    type: Decimal(18, 2)
    description: "Amount returned to the customer."
    checks:
      - name: non_negative
  - name: refund_reason
    type: LowCardinality(String)
    description: "Synthetic refund reason, or an empty string."
  - name: is_successful_order
    type: UInt8
    description: "Whether payment was captured and the order was not cancelled."
    checks:
      - name: accepted_values
        value: [0, 1]
  - name: is_cancelled_order
    type: UInt8
    description: "Whether the order was cancelled."
    checks:
      - name: accepted_values
        value: [0, 1]
  - name: has_refund
    type: UInt8
    description: "Whether the order has a refund record."
    checks:
      - name: accepted_values
        value: [0, 1]
  - name: refunded_merchandise_amount
    type: Decimal(18, 2)
    description: "Refund amount attributable to merchandise, capped at merchandise value."
    checks:
      - name: non_negative
  - name: net_revenue
    type: Decimal(18, 2)
    description: "Captured order total net of refunds."
    checks:
      - name: non_negative
  - name: recognized_cogs_amount
    type: Decimal(18, 2)
    description: "Product cost retained after cancellations and merchandise refunds."
    checks:
      - name: non_negative
  - name: recognized_shipping_cost
    type: Decimal(18, 2)
    description: "Fulfillment cost retained for successfully captured orders."
    checks:
      - name: non_negative
  - name: gross_profit
    type: Decimal(18, 2)
    description: "Net revenue less recognized product cost."
  - name: contribution_margin
    type: Decimal(18, 2)
    description: "Gross profit less fulfillment and payment-processing costs, before media spend."
@bruin */

WITH
    joined AS (
        SELECT
            o.order_id AS order_id,
            o.order_name AS order_name,
            o.customer_id AS customer_id,
            o.customer_email AS customer_email,
            o.order_date AS order_date,
            o.order_datetime AS order_datetime,
            o.market_id AS market_id,
            o.state AS state,
            o.city AS city,
            o.channel AS channel,
            o.event_id AS event_id,
            o.campaign_id AS campaign_id,
            o.line_item_count AS line_item_count,
            o.item_count AS item_count,
            o.order_status AS order_status,
            o.financial_status AS financial_status,
            o.fulfillment_status AS fulfillment_status,
            o.gross_merchandise_amount AS gross_merchandise_amount,
            o.discount_amount AS discount_amount,
            o.tax_amount AS tax_amount,
            o.shipping_revenue AS shipping_revenue,
            o.shipping_cost AS shipping_cost,
            o.cogs_amount AS cogs_amount,
            o.total_amount AS total_amount,
            p.payment_intent_id AS payment_intent_id,
            p.amount AS payment_amount,
            p.status AS payment_status,
            p.payment_method AS payment_method,
            p.payment_fee_amount AS payment_fee_amount,
            ifNull(r.refund_id, '') AS refund_id,
            ifNull(r.refund_amount, toDecimal64(0, 2)) AS refund_amount,
            toLowCardinality(ifNull(r.refund_reason, '')) AS refund_reason
        FROM bruin_shop.t1_orders AS o
        LEFT JOIN bruin_shop.t1_payment_intents AS p
            ON o.order_id = p.order_id
        LEFT JOIN bruin_shop.t1_refunds AS r
            ON o.order_id = r.order_id
        WHERE o.order_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
    ),
    classified AS (
        SELECT
            *,
            toDecimal64(gross_merchandise_amount - discount_amount, 2) AS net_merchandise_before_refund,
            toUInt8(
                CAST(payment_status AS String) = 'succeeded'
                AND CAST(order_status AS String) != 'cancelled'
            ) AS is_successful_order,
            toUInt8(CAST(order_status AS String) = 'cancelled') AS is_cancelled_order,
            toUInt8(refund_amount > 0) AS has_refund
        FROM joined
    ),
    refunded AS (
        SELECT
            *,
            toDecimal64(
                if(
                    is_successful_order = 1,
                    least(refund_amount, net_merchandise_before_refund),
                    toDecimal64(0, 2)
                ),
                2
            ) AS refunded_merchandise_amount,
            toDecimal64(
                if(
                    is_successful_order = 1,
                    greatest(total_amount - refund_amount, toDecimal64(0, 2)),
                    toDecimal64(0, 2)
                ),
                2
            ) AS net_revenue
        FROM classified
    ),
    costed AS (
        SELECT
            *,
            toDecimal64(
                if(
                    is_successful_order = 1 AND net_merchandise_before_refund > 0,
                    toFloat64(cogs_amount)
                        * toFloat64(net_merchandise_before_refund - refunded_merchandise_amount)
                        / toFloat64(net_merchandise_before_refund),
                    0
                ),
                2
            ) AS recognized_cogs_amount,
            toDecimal64(if(is_successful_order = 1, shipping_cost, toDecimal64(0, 2)), 2) AS recognized_shipping_cost
        FROM refunded
    )
SELECT
    order_id,
    order_name,
    customer_id,
    customer_email,
    order_date,
    toStartOfMonth(order_date) AS order_month,
    order_datetime,
    market_id,
    state,
    city,
    channel,
    event_id,
    campaign_id,
    line_item_count,
    item_count,
    order_status,
    financial_status,
    fulfillment_status,
    gross_merchandise_amount,
    discount_amount,
    net_merchandise_before_refund,
    tax_amount,
    shipping_revenue,
    shipping_cost,
    cogs_amount,
    total_amount,
    payment_intent_id,
    payment_amount,
    payment_status,
    payment_method,
    payment_fee_amount,
    refund_id,
    refund_amount,
    refund_reason,
    is_successful_order,
    is_cancelled_order,
    has_refund,
    refunded_merchandise_amount,
    net_revenue,
    recognized_cogs_amount,
    recognized_shipping_cost,
    toDecimal64(net_revenue - recognized_cogs_amount, 2) AS gross_profit,
    toDecimal64(
        net_revenue - recognized_cogs_amount - recognized_shipping_cost - payment_fee_amount,
        2
    ) AS contribution_margin
FROM costed
