/* @bruin
name: bruin_shop.t1_payment_intents_delete_interval
type: clickhouse.sql
description: "Deletes rows in the requested interval from `bruin_shop.t1_payment_intents` before its append load."
depends:
    - bruin_shop.t1_orders
@bruin */

{% if not full_refresh %}
ALTER TABLE bruin_shop.t1_payment_intents
DELETE WHERE toDate(created_at) BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
SETTINGS mutations_sync = 2
{% else %}
SELECT 1
{% endif %}
