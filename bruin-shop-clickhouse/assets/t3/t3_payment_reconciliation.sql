/* @bruin
name: bruin_shop.t3_payment_reconciliation
type: clickhouse.sql
description: "T3 daily reconciliation mart comparing order, payment-intent, and refund outcomes."
materialization:
   type: table
   strategy: append
depends:
    - bruin_shop.t2_orders
    - bruin_shop.t1_orders
    - bruin_shop.t1_payment_intents
    - bruin_shop.t1_refunds
    - bruin_shop.t3_payment_reconciliation_delete_interval

custom_checks:
  - name: contains rows
    description: Ensures the materialized table is not empty.
    query: SELECT count() > 0 FROM bruin_shop.t3_payment_reconciliation
    value: 1
    blocking: true
columns:
  - name: reconciliation_date
    type: date
    description: "Calendar date represented by the reconciliation row."
    primary_key: true
    checks:
        - name: not_null
        - name: unique
  - name: order_attempts
    type: integer
    description: "Number of order attempts in the period."
    checks:
      - name: non_negative
  - name: cancelled_orders
    type: integer
    description: "Number of cancelled order attempts."
  - name: successful_orders
    type: integer
    description: "Number of successfully paid orders."
    checks:
      - name: non_negative
  - name: payment_intents
    type: integer
    description: "Number of payment intents created in the period."
    checks:
      - name: non_negative
  - name: succeeded_payment_intents
    type: integer
    description: "Number of payment intents with a succeeded status."
    checks:
      - name: non_negative
  - name: canceled_payment_intents
    type: integer
    description: "Number of payment intents with a canceled status."
  - name: successful_order_gap
    type: integer
    description: "Difference between successful orders and succeeded payment intents."
  - name: successful_amount_gap
    type: float
    description: "Difference between successful order and successful payment-intent amounts."
  - name: refunded_orders
    type: integer
    description: "Number of refunded order attempts."
    checks:
      - name: non_negative
  - name: order_refund_amount
    type: float
    description: "Refund value calculated from order records."
    checks:
      - name: non_negative
  - name: stripe_refund_records
    type: integer
    description: "Number of refund records reported by the payment provider."
    checks:
      - name: non_negative
  - name: stripe_refund_amount
    type: float
    description: "Refund value calculated from payment-provider records."
    checks:
      - name: non_negative
@bruin */

WITH
    orders AS (
        SELECT
            order_date AS reconciliation_date,
            count() AS order_attempts,
            countIf(order_status = 'cancelled') AS cancelled_orders,
            countIf(order_status != 'cancelled') AS successful_orders,
            round(sumIf(total_amount, order_status != 'cancelled'), 2) AS successful_order_amount,
            countIf(has_refund = 1) AS refunded_orders,
            round(sum(refund_amount), 2) AS order_refund_amount
        FROM bruin_shop.t2_orders
        WHERE order_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
        GROUP BY order_date
    ),
    payments AS (
        SELECT
            toDate(created_at) AS reconciliation_date,
            count() AS payment_intents,
            countIf(status = 'succeeded') AS succeeded_payment_intents,
            countIf(status = 'canceled') AS canceled_payment_intents,
            round(sumIf(amount, status = 'succeeded'), 2) AS succeeded_payment_amount
        FROM bruin_shop.t1_payment_intents
        WHERE toDate(created_at) BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
        GROUP BY toDate(created_at)
    ),
    refunds AS (
        SELECT
            o.order_date AS reconciliation_date,
            count() AS refund_records,
            round(sum(r.refund_amount), 2) AS stripe_refund_amount
        FROM bruin_shop.t1_refunds AS r
        INNER JOIN bruin_shop.t1_orders AS o
            ON r.order_id = o.order_id
        WHERE o.order_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
        GROUP BY o.order_date
    )
SELECT
    o.reconciliation_date AS reconciliation_date,
    o.order_attempts AS order_attempts,
    o.cancelled_orders AS cancelled_orders,
    o.successful_orders AS successful_orders,
    ifNull(p.payment_intents, 0) AS payment_intents,
    ifNull(p.succeeded_payment_intents, 0) AS succeeded_payment_intents,
    ifNull(p.canceled_payment_intents, 0) AS canceled_payment_intents,
    o.successful_orders - ifNull(p.succeeded_payment_intents, 0) AS successful_order_gap,
    round(o.successful_order_amount - ifNull(p.succeeded_payment_amount, 0.00), 2) AS successful_amount_gap,
    o.refunded_orders AS refunded_orders,
    o.order_refund_amount AS order_refund_amount,
    ifNull(r.refund_records, 0) AS stripe_refund_records,
    ifNull(r.stripe_refund_amount, 0.00) AS stripe_refund_amount
FROM orders AS o
LEFT JOIN payments AS p
    ON o.reconciliation_date = p.reconciliation_date
LEFT JOIN refunds AS r
    ON o.reconciliation_date = r.reconciliation_date
SETTINGS insert_deduplicate = 0
