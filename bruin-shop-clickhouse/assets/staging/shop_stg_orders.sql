/* @bruin
name: shop_stg_orders
type: clickhouse.sql
materialization:
   type: table
depends:
    - shop_raw_orders
    - shop_raw_payment_intents
    - shop_raw_refunds

columns:
  - name: order_id
    type: integer
    primary_key: true
    checks:
        - name: not_null
        - name: unique
  - name: order_name
    type: varchar
  - name: customer_id
    type: integer
  - name: customer_email
    type: varchar
  - name: order_date
    type: date
  - name: order_month
    type: date
  - name: order_datetime
    type: datetime
  - name: market_id
    type: varchar
  - name: state
    type: varchar
  - name: city
    type: varchar
  - name: channel
    type: varchar
  - name: event_id
    type: varchar
  - name: campaign_id
    type: varchar
  - name: product_id
    type: varchar
  - name: product_name
    type: varchar
  - name: product_category
    type: varchar
  - name: item_count
    type: integer
  - name: order_status
    type: varchar
  - name: financial_status
    type: varchar
  - name: fulfillment_status
    type: varchar
  - name: gross_merchandise_amount
    type: float
  - name: discount_amount
    type: float
  - name: tax_amount
    type: float
  - name: shipping_revenue
    type: float
  - name: shipping_cost
    type: float
  - name: cogs_amount
    type: float
  - name: total_amount
    type: float
  - name: payment_intent_id
    type: varchar
  - name: payment_status
    type: varchar
  - name: payment_method
    type: varchar
  - name: payment_fee_amount
    type: float
  - name: refund_id
    type: varchar
  - name: refund_amount
    type: float
  - name: refund_reason
    type: varchar
  - name: is_successful_order
    type: integer
  - name: is_cancelled_order
    type: integer
  - name: has_refund
    type: integer
  - name: net_revenue
    type: float
  - name: gross_profit
    type: float
  - name: contribution_profit
    type: float
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
    FROM shop_raw_orders AS o
    LEFT JOIN shop_raw_payment_intents AS p
        ON o.order_id = p.order_id
    LEFT JOIN shop_raw_refunds AS r
        ON o.order_id = r.order_id
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
