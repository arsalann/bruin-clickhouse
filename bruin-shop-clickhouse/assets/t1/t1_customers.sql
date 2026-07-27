/* @bruin
name: bruin_shop.t1_customers
type: clickhouse.sql
description: "Synthetic Shopify-style T1 customer profiles at one row per customer."
materialization:
  type: table
  strategy: create+replace
depends:
  - bruin_shop.t1_markets

tags:
  - t1
  - source
  - synthetic
domains:
  - commerce
  - marketing
meta:
  grain: one row per customer
  source_system: synthetic_shopify

custom_checks:
  - name: contains customer population
    description: Ensures the deterministic customer population remains complete.
    query: SELECT count() FROM bruin_shop.t1_customers
    value: 120000
    blocking: true
columns:
  - name: customer_id
    type: UInt64
    description: "Stable identifier of the customer."
    primary_key: true
    checks:
      - name: not_null
      - name: unique
  - name: customer_email
    type: String
    description: "Synthetic customer email address."
    checks:
      - name: unique
  - name: first_name
    type: LowCardinality(String)
    description: "Given name of the customer."
  - name: last_name
    type: LowCardinality(String)
    description: "Family name of the customer."
  - name: customer_name
    type: LowCardinality(String)
    description: "Display name of the customer."
  - name: market_id
    type: String
    description: "Identifier of the market."
  - name: state
    type: LowCardinality(String)
    description: "State associated with the market or customer."
  - name: city
    type: LowCardinality(String)
    description: "City associated with the market or customer."
  - name: signup_channel
    type: LowCardinality(String)
    description: "Synthetic channel recorded on the customer profile at signup."
    checks:
      - name: accepted_values
        value: ["direct", "email", "organic", "paid_search", "paid_social"]
  - name: signup_date
    type: Date
    description: "Date on which the customer signed up."
@bruin */

WITH
    ['Alex', 'Jordan', 'Taylor', 'Morgan', 'Casey', 'Riley', 'Quinn', 'Avery', 'Parker', 'Drew', 'Jamie', 'Skyler'] AS first_names,
    ['Stone', 'Reed', 'Brooks', 'Hayes', 'Patel', 'Kim', 'Garcia', 'Nguyen', 'Carter', 'Bennett', 'Morris', 'Diaz'] AS last_names,
    ['paid_search', 'paid_social', 'email', 'organic', 'direct'] AS channels
SELECT
    toUInt64(n.number + 1) AS customer_id,
    concat('customer+', toString(n.number + 1), '@demo-shop.example') AS customer_email,
    toLowCardinality(arrayElement(first_names, toUInt32((n.number % length(first_names)) + 1))) AS first_name,
    toLowCardinality(arrayElement(last_names, toUInt32((intDiv(n.number, length(first_names)) % length(last_names)) + 1))) AS last_name,
    toLowCardinality(concat(first_name, ' ', last_name)) AS customer_name,
    m.market_id AS market_id,
    m.state AS state,
    m.city AS city,
    toLowCardinality(arrayElement(channels, toUInt32((cityHash64(toString(n.number), m.market_id, 'signup_channel') % length(channels)) + 1))) AS signup_channel,
    addDays(toDate('2024-07-01'), toUInt16(intDiv(intDiv(n.number, 12), 14))) AS signup_date
FROM numbers(120000) AS n
INNER JOIN bruin_shop.t1_markets AS m
    ON m.market_index = toUInt8((n.number % 12) + 1)
