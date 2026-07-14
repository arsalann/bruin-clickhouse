/* @bruin
name: shop_rpt_payment_reconciliation
type: clickhouse.sql
materialization:
   type: table
depends:
    - shop_stg_orders
    - shop_raw_orders
    - shop_raw_payment_intents
    - shop_raw_refunds

columns:
  - name: reconciliation_date
    type: date
    primary_key: true
    checks:
        - name: not_null
        - name: unique
  - name: order_attempts
    type: integer
  - name: cancelled_orders
    type: integer
  - name: successful_orders
    type: integer
  - name: payment_intents
    type: integer
  - name: succeeded_payment_intents
    type: integer
  - name: canceled_payment_intents
    type: integer
  - name: successful_order_gap
    type: integer
  - name: successful_amount_gap
    type: float
  - name: refunded_orders
    type: integer
  - name: order_refund_amount
    type: float
  - name: stripe_refund_records
    type: integer
  - name: stripe_refund_amount
    type: float
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
        FROM shop_stg_orders
        GROUP BY order_date
    ),
    payments AS (
        SELECT
            toDate(created_at) AS reconciliation_date,
            count() AS payment_intents,
            countIf(status = 'succeeded') AS succeeded_payment_intents,
            countIf(status = 'canceled') AS canceled_payment_intents,
            round(sumIf(amount, status = 'succeeded'), 2) AS succeeded_payment_amount
        FROM shop_raw_payment_intents
        GROUP BY toDate(created_at)
    ),
    refunds AS (
        SELECT
            o.order_date AS reconciliation_date,
            count() AS refund_records,
            round(sum(r.refund_amount), 2) AS stripe_refund_amount
        FROM shop_raw_refunds AS r
        INNER JOIN shop_raw_orders AS o
            ON r.order_id = o.order_id
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
