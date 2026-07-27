/* @bruin
name: bruin_shop.t1_refunds_delete_interval
type: clickhouse.sql
description: "Deletes rows in the requested interval from `bruin_shop.t1_refunds` before its append load."
depends:
    - bruin_shop.t1_orders
    - bruin_shop.t1_payment_intents
@bruin */

{% if not full_refresh %}
ALTER TABLE bruin_shop.t1_refunds
DELETE WHERE order_id IN (
    SELECT order_id
    FROM bruin_shop.t1_orders
    WHERE order_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
)
SETTINGS mutations_sync = 2
{% else %}
SELECT 1
{% endif %}
