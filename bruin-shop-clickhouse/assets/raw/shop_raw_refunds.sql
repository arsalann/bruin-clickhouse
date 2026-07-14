/* @bruin
name: shop_raw_refunds
type: clickhouse.sql
materialization:
   type: table
depends:
    - shop_raw_orders
    - shop_raw_payment_intents

columns:
  - name: refund_id
    type: varchar
    primary_key: true
    checks:
        - name: not_null
        - name: unique
  - name: payment_intent_id
    type: varchar
  - name: order_id
    type: integer
  - name: customer_id
    type: integer
  - name: refund_created_at
    type: datetime
  - name: refund_amount
    type: float
  - name: refund_reason
    type: varchar
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
FROM shop_raw_orders AS o
INNER JOIN shop_raw_payment_intents AS p
    ON o.order_id = p.order_id
WHERE o.order_status IN ('refunded', 'partially_refunded')
