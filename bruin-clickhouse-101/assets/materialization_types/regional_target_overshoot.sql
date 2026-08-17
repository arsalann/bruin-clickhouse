/* @bruin

name: regional_target_overshoot
type: clickhouse.sql
description: >-
  Demonstrates ClickHouse query-scoped WITH expression aliases. The two
  `__`-prefixed aliases are defined once in the WITH clause, reused in several
  aggregates, and never materialize as output columns because they are not
  named in the SELECT list. This behaves exactly like inlining the expressions
  into the SELECT, but keeps the aggregate list readable.
tags:
  - layer:serving
  - domain:commerce
  - materialization:view
  - clickhouse-feature:with-expression-alias
domains:
  - commerce
meta:
  consumer: analytics
  data_classification: internal
  clickhouse_feature: "WITH <expr> AS alias (query-scoped expression alias, not a CTE)"

materialization:
  type: view

depends:
  - country_revenue
owner: commerce-analytics@example.com

columns:
  - name: sales_region
    type: LowCardinality(String)
    description: Commercial sales region.
    primary_key: true
    checks:
      - name: not_null
      - name: unique
  - name: countries_over_target
    type: UInt64
    description: Countries in the region whose paid revenue exceeded the monthly target.
    checks:
      - name: non_negative
  - name: excess_revenue_over_target
    type: Float64
    description: Total paid revenue above target, summed only across over-performing countries.
    checks:
      - name: non_negative

custom_checks:
  - name: internal aliases do not leak into the view schema
    description: >-
      Proves the WITH expression aliases stay internal. The view must expose
      exactly three columns; if `__over_target` or `__exceeds_by` leaked, the
      count would be higher.
    value: 3
    query: |
      SELECT count()
      FROM system.columns
      WHERE database = currentDatabase()
        AND table = 'regional_target_overshoot'

@bruin */

WITH
    total_paid_amount > monthly_revenue_target AS __over_target,
    total_paid_amount - monthly_revenue_target AS __exceeds_by
SELECT
    sales_region                       AS "sales_region",
    countIf(__over_target)             AS "countries_over_target",
    sumIf(__exceeds_by, __over_target) AS "excess_revenue_over_target"
FROM country_revenue
GROUP BY sales_region
ORDER BY "excess_revenue_over_target" DESC
