/* @bruin
name: bruin_shop.t1_web_sessions_delete_interval
type: clickhouse.sql
description: "Deletes rows in the requested interval from `bruin_shop.t1_web_sessions` before its append load."
depends:
    - bruin_shop.t1_marketing_spend
    - bruin_shop.t1_special_events
@bruin */

{% if not full_refresh %}
ALTER TABLE bruin_shop.t1_web_sessions
DELETE WHERE session_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
SETTINGS mutations_sync = 2
{% else %}
SELECT 1
{% endif %}
