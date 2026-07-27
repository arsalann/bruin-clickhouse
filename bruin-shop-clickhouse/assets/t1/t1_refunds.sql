/* @bruin
name: bruin_shop.t1_refunds
type: clickhouse.sql
description: "Synthetic Stripe-style T1 refunds at one row per refunded order."
materialization:
  type: table
  strategy: time_interval
  incremental_key: order_date
  time_granularity: date
depends:
  - bruin_shop.t1_orders
  - bruin_shop.t1_order_line_items
  - bruin_shop.t1_payment_intents

tags:
  - t1
  - source
  - synthetic
domains:
  - commerce
  - finance
meta:
  grain: one row per refunded order
  source_system: synthetic_stripe

custom_checks:
  - name: refunds do not exceed captured amount
    description: Ensures no synthetic refund exceeds its payment-intent amount.
    query: |
      SELECT r.refund_id
      FROM bruin_shop.t1_refunds AS r
      INNER JOIN bruin_shop.t1_payment_intents AS p
        ON r.payment_intent_id = p.payment_intent_id
      WHERE r.order_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
        AND r.refund_amount > p.amount
    count: 0
    blocking: true
columns:
  - name: refund_id
    type: String
    description: "Stable Stripe-style refund identifier."
    primary_key: true
    checks:
      - name: not_null
      - name: unique
  - name: payment_intent_id
    type: String
    description: "Payment intent receiving the refund."
  - name: order_id
    type: UInt64
    description: "Stable identifier of the refunded order."
    checks:
      - name: unique
  - name: customer_id
    type: UInt64
    description: "Stable identifier of the customer."
  - name: order_date
    type: Date
    description: "Originating order date used as the incremental key."
  - name: refund_created_at
    type: DateTime('UTC')
    description: "Synthetic refund timestamp in UTC."
  - name: refund_amount
    type: Decimal(18, 2)
    description: "Refund amount in USD."
    checks:
      - name: positive
  - name: currency
    type: LowCardinality(String)
    description: "Uppercase ISO currency code."
    checks:
      - name: accepted_values
        value: ["USD"]
  - name: status
    type: LowCardinality(String)
    description: "Stripe-style refund status."
    checks:
      - name: accepted_values
        value: ["succeeded"]
  - name: refund_reason
    type: LowCardinality(String)
    description: "Synthetic reason assigned to the refund."
    checks:
      - name: accepted_values
        value: ["customer_return", "goodwill_partial_refund", "product_defect"]
@bruin */

WITH order_products AS (
    SELECT
        order_id,
        max(toUInt8(product_id = 'prod_accessories_09')) AS has_black_tote
    FROM bruin_shop.t1_order_line_items
    WHERE order_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
    GROUP BY order_id
)
SELECT
    concat('re_', leftPad(toString(o.order_id), 12, '0')) AS refund_id,
    p.payment_intent_id AS payment_intent_id,
    o.order_id AS order_id,
    o.customer_id AS customer_id,
    o.order_date AS order_date,
    o.order_datetime + toIntervalDay(toUInt16(1 + (cityHash64(toString(o.order_id), 'refund_delay') % 10))) AS refund_created_at,
    toDecimal64(
        multiIf(
            o.order_status = 'refunded', o.total_amount,
            o.event_id = 'product_defect_black_tote' AND op.has_black_tote = 1,
                o.total_amount * toDecimal64(0.72, 4),
            o.total_amount * toDecimal64(0.38, 4)
        ),
        2
    ) AS refund_amount,
    toLowCardinality('USD') AS currency,
    toLowCardinality('succeeded') AS status,
    toLowCardinality(
        multiIf(
            o.event_id = 'product_defect_black_tote' AND op.has_black_tote = 1, 'product_defect',
            o.order_status = 'refunded', 'customer_return',
            'goodwill_partial_refund'
        )
    ) AS refund_reason
FROM bruin_shop.t1_orders AS o
INNER JOIN bruin_shop.t1_payment_intents AS p
    ON o.order_id = p.order_id
INNER JOIN order_products AS op
    ON o.order_id = op.order_id
WHERE o.order_status IN ('refunded', 'partially_refunded')
  AND o.order_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
