/* @bruin
name: shop_raw_payment_intents
type: clickhouse.sql
materialization:
   type: table
depends:
    - shop_raw_orders

columns:
  - name: payment_intent_id
    type: varchar
    primary_key: true
    checks:
        - name: not_null
        - name: unique
  - name: order_id
    type: integer
  - name: customer_id
    type: integer
  - name: customer_email
    type: varchar
  - name: created_at
    type: datetime
  - name: amount
    type: float
  - name: currency
    type: varchar
  - name: status
    type: varchar
  - name: payment_method
    type: varchar
  - name: payment_fee_amount
    type: float
@bruin */

SELECT
    concat('pi_', toString(order_id)) AS payment_intent_id,
    order_id,
    customer_id,
    customer_email,
    order_datetime AS created_at,
    total_amount AS amount,
    'usd' AS currency,
    multiIf(order_status = 'cancelled', 'canceled', 'succeeded') AS status,
    arrayElement(['card', 'apple_pay', 'paypal', 'shop_pay'], toUInt32((cityHash64(toString(order_id), customer_email) % 4) + 1)) AS payment_method,
    round(if(status = 'succeeded', total_amount * 0.029 + 0.30, 0.00), 2) AS payment_fee_amount
FROM shop_raw_orders
