/* @bruin
name: bruin_shop.t1_refunds
type: clickhouse.sql
description: "T1 refund records associated with payment intents and orders."
materialization:
   type: table
   strategy: append
depends:
    - bruin_shop.t1_orders
    - bruin_shop.t1_payment_intents
    - bruin_shop.t1_refunds_delete_interval

custom_checks:
  - name: contains rows
    description: Ensures the materialized table is not empty.
    query: SELECT count() > 0 FROM bruin_shop.t1_refunds
    value: 1
    blocking: true
columns:
  - name: refund_id
    type: varchar
    description: "Stable identifier of the refund."
    primary_key: true
    checks:
        - name: not_null
        - name: unique
  - name: payment_intent_id
    type: varchar
    description: "Stable identifier of the payment intent."
  - name: order_id
    type: integer
    description: "Stable identifier of the order attempt."
  - name: customer_id
    type: integer
    description: "Stable identifier of the customer."
  - name: refund_created_at
    type: datetime
    description: "Timestamp when the refund was created."
  - name: refund_amount
    type: float
    description: "Monetary value refunded to the customer."
    checks:
      - name: non_negative
  - name: refund_reason
    type: varchar
    description: "Reason assigned to the refund."
@bruin */

SELECT
    concat('rf_', toString(o.order_id)) AS refund_id,
    p.payment_intent_id AS payment_intent_id,
    o.order_id AS order_id,
    o.customer_id AS customer_id,
    o.order_datetime + toIntervalDay(toUInt16(1 + (cityHash64(toString(o.order_id), 'refund') % 10))) AS refund_created_at,
    round(
        multiIf(
            o.order_status = 'refunded', o.total_amount,
            o.product_id = 'prod_accessories_09', o.total_amount * 0.72,
            o.total_amount * 0.38
        ),
        2
    ) AS refund_amount,
    multiIf(
        o.event_id = 'product_defect_black_tote' AND o.product_id = 'prod_accessories_09', 'product_defect',
        o.order_status = 'refunded', 'customer_return',
        'goodwill_partial_refund'
    ) AS refund_reason
FROM bruin_shop.t1_orders AS o
INNER JOIN bruin_shop.t1_payment_intents AS p
    ON o.order_id = p.order_id
WHERE o.order_status IN ('refunded', 'partially_refunded')
    AND o.order_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
SETTINGS insert_deduplicate = 0
