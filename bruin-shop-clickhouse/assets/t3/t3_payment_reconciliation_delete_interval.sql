/* @bruin
name: bruin_shop.t3_payment_reconciliation_delete_interval
type: clickhouse.sql
description: "Deletes rows in the requested interval from `bruin_shop.t3_payment_reconciliation` before its append load."
depends:
    - bruin_shop.t2_orders
    - bruin_shop.t1_orders
    - bruin_shop.t1_payment_intents
    - bruin_shop.t1_refunds
@bruin */

{% if not full_refresh %}
ALTER TABLE bruin_shop.t3_payment_reconciliation
DELETE WHERE reconciliation_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
SETTINGS mutations_sync = 2
{% else %}
SELECT 1
{% endif %}
