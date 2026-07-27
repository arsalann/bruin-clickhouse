/* @bruin
name: bruin_shop.t1_orders_delete_interval
type: clickhouse.sql
description: "Deletes rows in the requested interval from `bruin_shop.t1_orders` before its append load."
depends:
    - bruin_shop.t1_web_sessions
    - bruin_shop.t1_special_events
    - bruin_shop.t1_products
    - bruin_shop.t1_customers
    - bruin_shop.t1_markets
@bruin */

{% if not full_refresh %}
ALTER TABLE bruin_shop.t1_orders
DELETE WHERE order_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
SETTINGS mutations_sync = 2
{% else %}
SELECT 1
{% endif %}
