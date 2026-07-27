/* @bruin
name: bruin_shop.t2_orders
type: clickhouse.sql
description: "T2 standardized order fact enriched with payment, refund, and profitability measures."
materialization:
   type: table
   strategy: append
depends:
    - bruin_shop.t1_orders
    - bruin_shop.t1_payment_intents
    - bruin_shop.t1_refunds
    - bruin_shop.t2_orders_delete_interval

custom_checks:
  - name: contains rows
    description: Ensures the materialized table is not empty.
    query: SELECT count() > 0 FROM bruin_shop.t2_orders
    value: 1
    blocking: true
columns:
  - name: order_id
    type: integer
    description: "Stable identifier of the order attempt."
    primary_key: true
    checks:
        - name: not_null
        - name: unique
  - name: order_name
    type: varchar
    description: "Customer-facing order reference."
  - name: customer_id
    type: integer
    description: "Stable identifier of the customer."
  - name: customer_email
    type: varchar
    description: "Email address associated with the customer or order."
  - name: order_date
    type: date
    description: "Calendar date on which the order was placed."
  - name: order_month
    type: date
    description: "Month containing the order date."
  - name: order_datetime
    type: datetime
    description: "Timestamp at which the order was placed."
  - name: market_id
    type: varchar
    description: "Identifier of the market."
  - name: state
    type: varchar
    description: "State associated with the market or customer."
  - name: city
    type: varchar
    description: "City associated with the market or customer."
  - name: channel
    type: varchar
    description: "Marketing or acquisition channel associated with the record."
    checks:
      - name: accepted_values
        value: ["direct", "email", "organic", "paid_search", "paid_social"]
  - name: event_id
    type: varchar
    description: "Identifier of the associated special event."
  - name: campaign_id
    type: varchar
    description: "Identifier of the marketing campaign associated with the record."
  - name: product_id
    type: varchar
    description: "Stable identifier of the product."
  - name: product_name
    type: varchar
    description: "Display name of the product."
  - name: product_category
    type: varchar
    description: "Merchandise category of the ordered product."
  - name: item_count
    type: integer
    description: "Number of units included in the order."
    checks:
      - name: positive
  - name: order_status
    type: varchar
    description: "Lifecycle status assigned to the order attempt."
    checks:
      - name: accepted_values
        value: ["cancelled", "paid", "partially_refunded", "refunded"]
  - name: financial_status
    type: varchar
    description: "Payment and refund state assigned to the order."
    checks:
      - name: accepted_values
        value: ["paid", "refunded", "voided"]
  - name: fulfillment_status
    type: varchar
    description: "Fulfilment state assigned to the order."
    checks:
      - name: accepted_values
        value: ["cancelled", "fulfilled", "unfulfilled"]
  - name: gross_merchandise_amount
    type: float
    description: "Pre-discount merchandise value of the order."
  - name: discount_amount
    type: float
    description: "Discount value applied to the order."
    checks:
      - name: non_negative
  - name: tax_amount
    type: float
    description: "Tax charged on the order or period."
    checks:
      - name: non_negative
  - name: shipping_revenue
    type: float
    description: "Shipping revenue charged on the order or period."
    checks:
      - name: non_negative
  - name: shipping_cost
    type: float
    description: "Shipping cost incurred for the order or period."
    checks:
      - name: non_negative
  - name: cogs_amount
    type: float
    description: "Cost of goods sold associated with the order or period."
    checks:
      - name: non_negative
  - name: total_amount
    type: float
    description: "Final amount charged for the order."
    checks:
      - name: non_negative
  - name: payment_intent_id
    type: varchar
    description: "Stable identifier of the payment intent."
  - name: payment_status
    type: varchar
    description: "Resolved payment-intent status associated with the order."
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
  - name: refund_id
    type: varchar
    description: "Stable identifier of the refund."
  - name: refund_amount
    type: float
    description: "Monetary value refunded to the customer."
    checks:
      - name: non_negative
  - name: refund_reason
    type: varchar
    description: "Reason assigned to the refund."
  - name: is_successful_order
    type: integer
    description: "Whether the order completed successfully."
  - name: is_cancelled_order
    type: integer
    description: "Whether the order was cancelled."
  - name: has_refund
    type: integer
    description: "Whether the order has an associated refund."
  - name: net_revenue
    type: float
    description: "Revenue after discounts, refunds, and applicable adjustments."
    checks:
      - name: non_negative
  - name: gross_profit
    type: float
    description: "Net revenue less cost of goods sold and shipping cost."
  - name: contribution_profit
    type: float
    description: "Net revenue less variable marketing, fulfilment, and product costs."
@bruin */

WITH enriched AS (
    SELECT
        o.order_id AS order_id,
        o.order_name AS order_name,
        o.customer_id AS customer_id,
        o.customer_email AS customer_email,
        o.order_date AS order_date,
        toStartOfMonth(o.order_date) AS order_month,
        o.order_datetime AS order_datetime,
        o.market_id AS market_id,
        o.state AS state,
        o.city AS city,
        o.channel AS channel,
        o.event_id AS event_id,
        o.campaign_id AS campaign_id,
        o.product_id AS product_id,
        o.product_name AS product_name,
        o.product_category AS product_category,
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
        p.status AS payment_status,
        p.payment_method AS payment_method,
        p.payment_fee_amount AS payment_fee_amount,
        ifNull(r.refund_id, '') AS refund_id,
        ifNull(r.refund_amount, 0.00) AS refund_amount,
        ifNull(r.refund_reason, '') AS refund_reason
    FROM bruin_shop.t1_orders AS o
    LEFT JOIN bruin_shop.t1_payment_intents AS p
        ON o.order_id = p.order_id
    LEFT JOIN bruin_shop.t1_refunds AS r
        ON o.order_id = r.order_id
    WHERE o.order_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
)
SELECT
    *,
    toUInt8(order_status IN ('paid', 'partially_refunded') AND payment_status = 'succeeded') AS is_successful_order,
    toUInt8(order_status = 'cancelled') AS is_cancelled_order,
    toUInt8(order_status IN ('refunded', 'partially_refunded')) AS has_refund,
    round(
        multiIf(
            order_status = 'paid', total_amount,
            order_status = 'partially_refunded', greatest(total_amount - refund_amount, 0),
            0.00
        ),
        2
    ) AS net_revenue,
    round(
        multiIf(
            order_status = 'paid', total_amount,
            order_status = 'partially_refunded', greatest(total_amount - refund_amount, 0),
            0.00
        ) - cogs_amount,
        2
    ) AS gross_profit,
    round(
        multiIf(
            order_status = 'paid', total_amount,
            order_status = 'partially_refunded', greatest(total_amount - refund_amount, 0),
            0.00
        ) - cogs_amount - shipping_cost - payment_fee_amount,
        2
    ) AS contribution_profit
FROM enriched
SETTINGS insert_deduplicate = 0
