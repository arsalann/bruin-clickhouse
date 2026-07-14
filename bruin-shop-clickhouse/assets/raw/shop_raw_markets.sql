/* @bruin
name: shop_raw_markets
type: clickhouse.sql
materialization:
   type: table

columns:
  - name: market_id
    type: varchar
    primary_key: true
    checks:
        - name: not_null
        - name: unique
  - name: market_index
    type: integer
  - name: state
    type: varchar
  - name: city
    type: varchar
  - name: region
    type: varchar
  - name: demand_weight
    type: float
  - name: tax_rate
    type: float
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
    tupleElement(market, 2) AS state,
    tupleElement(market, 3) AS city,
    tupleElement(market, 4) AS region,
    toFloat64(tupleElement(market, 5)) AS demand_weight,
    toFloat64(tupleElement(market, 6)) AS tax_rate
