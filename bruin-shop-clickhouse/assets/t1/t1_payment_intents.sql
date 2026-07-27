/* @bruin
name: bruin_shop.t1_payment_intents
type: clickhouse.sql
description: "Synthetic Stripe-style T1 payment intents at one row per order attempt."
materialization:
  type: table
  strategy: time_interval
  incremental_key: payment_date
  time_granularity: date
depends:
  - bruin_shop.t1_orders

tags:
  - t1
  - source
  - synthetic
domains:
  - finance
meta:
  grain: one row per order attempt
  source_system: synthetic_stripe

custom_checks:
  - name: every interval order has one payment intent
    description: Ensures one-to-one order and payment-intent coverage for the requested interval.
    query: |
      SELECT o.order_id
      FROM bruin_shop.t1_orders AS o
      LEFT JOIN bruin_shop.t1_payment_intents AS p
        ON o.order_id = p.order_id
      WHERE o.order_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
      GROUP BY o.order_id
      HAVING countIf(p.payment_intent_id != '') != 1
    count: 0
    blocking: true
columns:
  - name: payment_intent_id
    type: String
    description: "Stable Stripe-style payment-intent identifier."
    primary_key: true
    checks:
      - name: not_null
      - name: unique
  - name: order_id
    type: UInt64
    description: "Stable identifier of the order attempt."
    checks:
      - name: unique
  - name: customer_id
    type: UInt64
    description: "Stable identifier of the customer."
  - name: customer_email
    type: String
    description: "Synthetic customer email address."
  - name: payment_date
    type: Date
    description: "Calendar date on which the payment intent was created."
  - name: created_at
    type: DateTime('UTC')
    description: "Timestamp at which the payment intent was created in UTC."
  - name: amount
    type: Decimal(18, 2)
    description: "Amount presented for payment in USD."
    checks:
      - name: non_negative
  - name: currency
    type: LowCardinality(String)
    description: "Uppercase ISO currency code."
    checks:
      - name: accepted_values
        value: ["USD"]
  - name: status
    type: LowCardinality(String)
    description: "Stripe-style payment-intent status."
    checks:
      - name: accepted_values
        value: ["canceled", "succeeded"]
  - name: payment_method
    type: LowCardinality(String)
    description: "Synthetic payment method."
    checks:
      - name: accepted_values
        value: ["apple_pay", "card", "paypal", "shop_pay"]
  - name: payment_fee_amount
    type: Decimal(18, 2)
    description: "Modeled processor fee in USD."
    checks:
      - name: non_negative
@bruin */

SELECT
    concat('pi_', leftPad(toString(order_id), 12, '0')) AS payment_intent_id,
    order_id,
    customer_id,
    customer_email,
    order_date AS payment_date,
    order_datetime AS created_at,
    total_amount AS amount,
    toLowCardinality('USD') AS currency,
    toLowCardinality(multiIf(order_status = 'cancelled', 'canceled', 'succeeded')) AS status,
    toLowCardinality(
        arrayElement(
            ['card', 'apple_pay', 'paypal', 'shop_pay'],
            toUInt32((cityHash64(toString(order_id), customer_email, 'payment_method') % 4) + 1)
        )
    ) AS payment_method,
    toDecimal64(
        if(
            status = 'succeeded',
            toDecimal64(
                amount * toDecimal64(0.029, 4) + toDecimal64(0.30, 2),
                2
            ),
            toDecimal64(0, 2)
        ),
        2
    ) AS payment_fee_amount
FROM bruin_shop.t1_orders
WHERE order_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
