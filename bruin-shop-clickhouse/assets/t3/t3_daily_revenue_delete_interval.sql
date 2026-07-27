/* @bruin
name: bruin_shop.t3_daily_revenue_delete_interval
type: clickhouse.sql
description: "Deletes rows in the requested interval from `bruin_shop.t3_daily_revenue` before its append load."
depends:
    - bruin_shop.t2_orders
@bruin */

{% if not full_refresh %}
ALTER TABLE bruin_shop.t3_daily_revenue
DELETE WHERE revenue_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
SETTINGS mutations_sync = 2
{% else %}
SELECT 1
{% endif %}
