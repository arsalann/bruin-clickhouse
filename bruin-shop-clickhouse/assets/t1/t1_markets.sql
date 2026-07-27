/* @bruin
name: bruin_shop.t1_markets
type: clickhouse.sql
description: "Synthetic T1 market dimension at one row per US city market."
materialization:
  type: table
  strategy: create+replace

tags:
  - t1
  - source
  - synthetic
domains:
  - commerce
  - marketing
meta:
  grain: one row per market
  source_system: synthetic_reference

custom_checks:
  - name: contains twelve demo markets
    description: Ensures the fixed market catalog remains complete.
    query: SELECT count() FROM bruin_shop.t1_markets
    value: 12
    blocking: true
columns:
  - name: market_id
    type: String
    description: "Stable identifier of the city market."
    primary_key: true
    checks:
      - name: not_null
      - name: unique
  - name: market_index
    type: UInt8
    description: "Stable numeric market ordering used by synthetic keys."
    checks:
      - name: positive
      - name: unique
  - name: state
    type: LowCardinality(String)
    description: "Two-letter US state code."
  - name: city
    type: LowCardinality(String)
    description: "City represented by the market."
  - name: region
    type: LowCardinality(String)
    description: "US census-style region containing the market."
  - name: demand_weight
    type: Float64
    description: "Relative demand multiplier used by the synthetic source model."
    checks:
      - name: positive
  - name: tax_rate
    type: Decimal(18, 4)
    description: "Simplified sales-tax rate applied to generated orders."
    checks:
      - name: non_negative
      - name: max
        value: 0.2
@bruin */

WITH arrayJoin([
    (1, 'CA', 'Los Angeles', 'West', 1.35, 0.095),
    (2, 'CA', 'San Francisco', 'West', 1.18, 0.086),
    (3, 'NY', 'New York', 'Northeast', 1.32, 0.088),
    (4, 'TX', 'Austin', 'South', 1.04, 0.0825),
    (5, 'TX', 'Dallas', 'South', 1.02, 0.0825),
    (6, 'FL', 'Miami', 'South', 0.98, 0.070),
    (7, 'IL', 'Chicago', 'Midwest', 1.08, 0.1025),
    (8, 'WA', 'Seattle', 'West', 1.10, 0.101),
    (9, 'CO', 'Denver', 'West', 0.92, 0.088),
    (10, 'GA', 'Atlanta', 'South', 0.96, 0.089),
    (11, 'MA', 'Boston', 'Northeast', 0.94, 0.063),
    (12, 'AZ', 'Phoenix', 'West', 0.86, 0.086)
]) AS market
SELECT
    concat(tupleElement(market, 2), '-', replaceAll(lower(tupleElement(market, 3)), ' ', '-')) AS market_id,
    toUInt8(tupleElement(market, 1)) AS market_index,
    toLowCardinality(tupleElement(market, 2)) AS state,
    toLowCardinality(tupleElement(market, 3)) AS city,
    toLowCardinality(tupleElement(market, 4)) AS region,
    toFloat64(tupleElement(market, 5)) AS demand_weight,
    toDecimal64(tupleElement(market, 6), 4) AS tax_rate
