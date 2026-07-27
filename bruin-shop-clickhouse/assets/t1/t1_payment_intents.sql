/* @bruin
name: bruin_shop.t1_payment_intents
type: clickhouse.sql
description: "T1 payment-intent records associated with ecommerce order attempts."
materialization:
   type: table
   strategy: append
depends:
    - bruin_shop.t1_orders
    - bruin_shop.t1_payment_intents_delete_interval

custom_checks:
  - name: contains rows
    description: Ensures the materialized table is not empty.
    query: SELECT count() > 0 FROM bruin_shop.t1_payment_intents
    value: 1
    blocking: true
columns:
  - name: payment_intent_id
    type: varchar
    description: "Stable identifier of the payment intent."
    primary_key: true
    checks:
        - name: not_null
        - name: unique
  - name: order_id
    type: integer
    description: "Stable identifier of the order attempt."
  - name: customer_id
    type: integer
    description: "Stable identifier of the customer."
  - name: customer_email
    type: varchar
    description: "Email address associated with the customer or order."
  - name: created_at
    type: datetime
    description: "Timestamp when the payment intent was created."
  - name: amount
    type: float
    description: "Monetary amount recorded on the payment intent."
    checks:
      - name: non_negative
  - name: currency
    type: varchar
    description: "ISO currency code used for the payment amount."
    checks:
      - name: accepted_values
        value: ["USD"]
  - name: status
    type: varchar
    description: "Status reported by the payment intent."
    checks:
      - name: accepted_values
        value: ["canceled", "succeeded"]
  - name: payment_method
    type: varchar
    description: "Payment method used to settle the payment intent."
  - name: payment_fee_amount
    type: float
    description: "Processing fee charged for the payment intent."
    checks:
      - name: non_negative
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
FROM bruin_shop.t1_orders
WHERE order_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
SETTINGS insert_deduplicate = 0
