/* @bruin
name: shop_raw_customers
type: clickhouse.sql
materialization:
   type: table
depends:
    - shop_raw_markets

columns:
  - name: customer_id
    type: integer
    primary_key: true
    checks:
        - name: not_null
        - name: unique
  - name: customer_email
    type: varchar
  - name: first_name
    type: varchar
  - name: last_name
    type: varchar
  - name: customer_name
    type: varchar
  - name: market_id
    type: varchar
  - name: state
    type: varchar
  - name: city
    type: varchar
  - name: acquisition_channel
    type: varchar
  - name: signup_date
    type: date
  - name: source_lifecycle_segment
    type: varchar
@bruin */

WITH
    ['Alex', 'Jordan', 'Taylor', 'Morgan', 'Casey', 'Riley', 'Quinn', 'Avery', 'Parker', 'Drew', 'Jamie', 'Skyler'] AS first_names,
    ['Stone', 'Reed', 'Brooks', 'Hayes', 'Patel', 'Kim', 'Garcia', 'Nguyen', 'Carter', 'Bennett', 'Morris', 'Diaz'] AS last_names,
    ['paid_search', 'paid_social', 'email', 'organic', 'direct'] AS channels
SELECT
    toUInt64(n.number + 1) AS customer_id,
    concat('customer+', toString(n.number + 1), '@example.shop') AS customer_email,
    arrayElement(first_names, toUInt32((n.number % length(first_names)) + 1)) AS first_name,
    arrayElement(last_names, toUInt32((intDiv(n.number, length(first_names)) % length(last_names)) + 1)) AS last_name,
    concat(first_name, ' ', last_name) AS customer_name,
    m.market_id AS market_id,
    m.state AS state,
    m.city AS city,
    arrayElement(channels, toUInt32((cityHash64(toString(n.number), m.market_id) % length(channels)) + 1)) AS acquisition_channel,
    addDays(toDate('2025-08-01'), toUInt16(cityHash64(toString(n.number), 'signup') % 210)) AS signup_date,
    multiIf(n.number % 100 < 9, 'high_intent', n.number % 100 < 34, 'repeat_candidate', 'new_prospect') AS source_lifecycle_segment
FROM numbers(8000) AS n
INNER JOIN shop_raw_markets AS m
    ON m.market_index = toUInt8((n.number % 12) + 1)
