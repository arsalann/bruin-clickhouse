/* @bruin
name: bruin_shop.t3_marketing_roi_delete_interval
type: clickhouse.sql
description: "Deletes rows in the requested interval from `bruin_shop.t3_marketing_roi` before its append load."
depends:
    - bruin_shop.t2_marketing_spend
    - bruin_shop.t2_web_sessions
    - bruin_shop.t2_orders
@bruin */

{% if not full_refresh %}
ALTER TABLE bruin_shop.t3_marketing_roi
DELETE WHERE spend_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
SETTINGS mutations_sync = 2
{% else %}
SELECT 1
{% endif %}
