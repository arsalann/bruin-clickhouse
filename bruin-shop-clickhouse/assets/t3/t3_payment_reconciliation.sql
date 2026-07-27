/* @bruin
name: bruin_shop.t3_payment_reconciliation
type: clickhouse.sql
description: "T3 daily reconciliation of order attempts, payment intents, captured amounts, and refunds."
materialization:
  type: table
  strategy: time_interval
  incremental_key: reconciliation_date
  time_granularity: date
depends:
  - bruin_shop.t2_orders
  - bruin_shop.t1_payment_intents
  - bruin_shop.t1_refunds

tags:
  - t3
  - mart
domains:
  - finance
meta:
  grain: one row per calendar date

custom_checks:
  - name: interval contains reconciliation rows
    description: Ensures the requested interval contains daily reconciliation rows.
    query: |
      SELECT count() > 0
      FROM bruin_shop.t3_payment_reconciliation
      WHERE reconciliation_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
    value: 1
    blocking: true
  - name: daily payments and refunds reconcile
    description: Ensures order counts, captured amounts, and refunds agree with provider-style records.
    query: |
      SELECT reconciliation_date
      FROM bruin_shop.t3_payment_reconciliation
      WHERE reconciliation_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
        AND (
          payment_intent_count_gap != 0
          OR succeeded_payment_count_gap != 0
          OR succeeded_payment_amount_gap != 0
          OR refund_record_count_gap != 0
          OR refund_amount_gap != 0
        )
    count: 0
    blocking: true

columns:
  - name: reconciliation_date
    type: Date
    description: "Calendar date represented by the reconciliation row."
    primary_key: true
    checks:
      - name: not_null
      - name: unique
  - name: order_attempts
    type: UInt64
    description: "Number of all order attempts."
  - name: cancelled_orders
    type: UInt64
    description: "Number of cancelled order attempts."
  - name: successful_orders
    type: UInt64
    description: "Number of successfully captured orders."
  - name: payment_intents
    type: UInt64
    description: "Number of payment intents."
  - name: succeeded_payment_intents
    type: UInt64
    description: "Number of succeeded payment intents."
  - name: canceled_payment_intents
    type: UInt64
    description: "Number of canceled payment intents."
  - name: payment_intent_count_gap
    type: Int64
    description: "Order attempts minus payment intents."
  - name: succeeded_payment_count_gap
    type: Int64
    description: "Successfully captured orders minus succeeded payment intents."
  - name: successful_order_amount
    type: Decimal(18, 2)
    description: "Payment amount on successfully captured orders."
    checks:
      - name: non_negative
  - name: succeeded_payment_amount
    type: Decimal(18, 2)
    description: "Amount on succeeded payment intents."
    checks:
      - name: non_negative
  - name: succeeded_payment_amount_gap
    type: Decimal(18, 2)
    description: "Successful-order payment amount minus succeeded-intent amount."
  - name: refunded_orders
    type: UInt64
    description: "Number of orders with refund records."
  - name: provider_refund_records
    type: UInt64
    description: "Number of provider-style refund records."
  - name: refund_record_count_gap
    type: Int64
    description: "Refunded orders minus provider-style refund records."
  - name: order_refund_amount
    type: Decimal(18, 2)
    description: "Refund amount carried on conformed orders."
    checks:
      - name: non_negative
  - name: provider_refund_amount
    type: Decimal(18, 2)
    description: "Refund amount from provider-style records."
    checks:
      - name: non_negative
  - name: refund_amount_gap
    type: Decimal(18, 2)
    description: "Conformed-order refunds minus provider-style refunds."
@bruin */

WITH
    orders AS (
        SELECT
            order_date AS reconciliation_date,
            count() AS order_attempts,
            countIf(is_cancelled_order = 1) AS cancelled_orders,
            countIf(is_successful_order = 1) AS successful_orders,
            toDecimal64(sumIf(payment_amount, is_successful_order = 1), 2) AS successful_order_amount,
            countIf(has_refund = 1) AS refunded_orders,
            toDecimal64(sum(refund_amount), 2) AS order_refund_amount
        FROM bruin_shop.t2_orders
        WHERE order_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
        GROUP BY order_date
    ),
    payments AS (
        SELECT
            payment_date AS reconciliation_date,
            count() AS payment_intents,
            countIf(status = 'succeeded') AS succeeded_payment_intents,
            countIf(status = 'canceled') AS canceled_payment_intents,
            toDecimal64(sumIf(amount, status = 'succeeded'), 2) AS succeeded_payment_amount
        FROM bruin_shop.t1_payment_intents
        WHERE payment_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
        GROUP BY payment_date
    ),
    refunds AS (
        SELECT
            order_date AS reconciliation_date,
            count() AS provider_refund_records,
            toDecimal64(sum(refund_amount), 2) AS provider_refund_amount
        FROM bruin_shop.t1_refunds
        WHERE order_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
        GROUP BY order_date
    ),
    joined AS (
        SELECT
            o.reconciliation_date AS reconciliation_date,
            o.order_attempts AS order_attempts,
            o.cancelled_orders AS cancelled_orders,
            o.successful_orders AS successful_orders,
            o.successful_order_amount AS successful_order_amount,
            o.refunded_orders AS refunded_orders,
            o.order_refund_amount AS order_refund_amount,
            ifNull(p.payment_intents, toUInt64(0)) AS payment_intents,
            ifNull(p.succeeded_payment_intents, toUInt64(0)) AS succeeded_payment_intents,
            ifNull(p.canceled_payment_intents, toUInt64(0)) AS canceled_payment_intents,
            ifNull(p.succeeded_payment_amount, toDecimal64(0, 2)) AS succeeded_payment_amount,
            ifNull(r.provider_refund_records, toUInt64(0)) AS provider_refund_records,
            ifNull(r.provider_refund_amount, toDecimal64(0, 2)) AS provider_refund_amount
        FROM orders AS o
        LEFT JOIN payments AS p
            ON o.reconciliation_date = p.reconciliation_date
        LEFT JOIN refunds AS r
            ON o.reconciliation_date = r.reconciliation_date
    )
SELECT
    reconciliation_date,
    order_attempts,
    cancelled_orders,
    successful_orders,
    payment_intents,
    succeeded_payment_intents,
    canceled_payment_intents,
    toInt64(order_attempts) - toInt64(payment_intents) AS payment_intent_count_gap,
    toInt64(successful_orders) - toInt64(succeeded_payment_intents) AS succeeded_payment_count_gap,
    successful_order_amount,
    succeeded_payment_amount,
    toDecimal64(successful_order_amount - succeeded_payment_amount, 2) AS succeeded_payment_amount_gap,
    refunded_orders,
    provider_refund_records,
    toInt64(refunded_orders) - toInt64(provider_refund_records) AS refund_record_count_gap,
    order_refund_amount,
    provider_refund_amount,
    toDecimal64(order_refund_amount - provider_refund_amount, 2) AS refund_amount_gap
FROM joined
