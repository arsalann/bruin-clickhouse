/* @bruin
name: bruin_shop.t3_daily_kpis_delete_interval
type: clickhouse.sql
description: "Deletes rows in the requested interval from `bruin_shop.t3_daily_kpis` before its append load."
depends:
    - bruin_shop.t3_daily_revenue
    - bruin_shop.t2_web_sessions
    - bruin_shop.t2_marketing_spend
    - bruin_shop.t2_customers
@bruin */

{% if not full_refresh %}
ALTER TABLE bruin_shop.t3_daily_kpis
DELETE WHERE metric_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
SETTINGS mutations_sync = 2
{% else %}
SELECT 1
{% endif %}
