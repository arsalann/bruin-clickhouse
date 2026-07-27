/* @bruin
name: bruin_shop.t1_products
type: clickhouse.sql
description: "Synthetic Shopify-style T1 product catalog at one row per product."
materialization:
  type: table
  strategy: create+replace

tags:
  - t1
  - source
  - synthetic
domains:
  - commerce
meta:
  grain: one row per product
  source_system: synthetic_shopify

custom_checks:
  - name: contains twenty demo products
    description: Ensures the fixed product catalog remains complete.
    query: SELECT count() FROM bruin_shop.t1_products
    value: 20
    blocking: true
  - name: unit cost does not exceed price
    description: Ensures every product has a non-negative catalog margin.
    query: |
      SELECT product_id
      FROM bruin_shop.t1_products
      WHERE unit_cogs > list_price
    count: 0
    blocking: true
columns:
  - name: product_id
    type: String
    description: "Stable identifier of the product."
    primary_key: true
    checks:
      - name: not_null
      - name: unique
  - name: product_name
    type: String
    description: "Display name of the product."
  - name: category
    type: LowCardinality(String)
    description: "Merchandise category assigned to the product."
    checks:
      - name: accepted_values
        value: ["accessories", "pants", "shoes", "tshirts"]
  - name: sku
    type: String
    description: "Stock-keeping unit assigned to the product."
    checks:
      - name: unique
  - name: list_price
    type: Decimal(18, 2)
    description: "Catalog unit price in USD."
    checks:
      - name: positive
  - name: unit_cogs
    type: Decimal(18, 2)
    description: "Standard unit cost in USD."
    checks:
      - name: non_negative
  - name: inventory_on_hand
    type: UInt32
    description: "Current synthetic sellable inventory units."
    checks:
      - name: non_negative
  - name: is_active
    type: UInt8
    description: "Whether the product is active in the catalog."
    checks:
      - name: accepted_values
        value: [0, 1]
  - name: launch_date
    type: Date
    description: "Date on which the product was launched."
@bruin */

WITH arrayJoin([
    ('prod_tshirt_01', 'Essential White Tee', 'tshirts', 'TEE-WHT-001', 28.00, 8.40, 1240),
    ('prod_tshirt_02', 'Vintage Black Tee', 'tshirts', 'TEE-BLK-002', 32.00, 9.80, 980),
    ('prod_tshirt_03', 'Navy Pocket Tee', 'tshirts', 'TEE-NVY-003', 34.00, 10.25, 860),
    ('prod_tshirt_04', 'Washed Green Tee', 'tshirts', 'TEE-GRN-004', 30.00, 9.20, 770),
    ('prod_pants_01', 'Slim Denim Jean', 'pants', 'PNT-DNM-001', 88.00, 34.00, 520),
    ('prod_pants_02', 'Black Travel Chino', 'pants', 'PNT-BLK-002', 82.00, 31.50, 610),
    ('prod_pants_03', 'Olive Utility Pant', 'pants', 'PNT-OLV-003', 92.00, 36.00, 430),
    ('prod_pants_04', 'Everyday Jogger', 'pants', 'PNT-JOG-004', 68.00, 24.50, 710),
    ('prod_shoes_01', 'White Court Sneaker', 'shoes', 'SHO-WHT-001', 118.00, 48.00, 390),
    ('prod_shoes_02', 'Black Knit Runner', 'shoes', 'SHO-BLK-002', 128.00, 52.00, 360),
    ('prod_shoes_03', 'Canvas Low Top', 'shoes', 'SHO-CVS-003', 74.00, 29.00, 590),
    ('prod_shoes_04', 'Heather Gray Trail Shoes', 'shoes', 'SHO-TRL-004', 142.00, 61.00, 26),
    ('prod_accessories_01', 'Ribbed Crew Socks', 'accessories', 'ACC-SCK-001', 14.00, 3.20, 2400),
    ('prod_accessories_02', 'Canvas Cap', 'accessories', 'ACC-CAP-002', 26.00, 7.50, 1180),
    ('prod_accessories_03', 'Leather Belt', 'accessories', 'ACC-BLT-003', 48.00, 18.00, 420),
    ('prod_accessories_04', 'Merino Beanie', 'accessories', 'ACC-BNE-004', 34.00, 11.00, 650),
    ('prod_accessories_05', 'Weekender Duffel', 'accessories', 'ACC-DUF-005', 96.00, 39.00, 220),
    ('prod_accessories_06', 'Classic Backpack', 'accessories', 'ACC-BPK-006', 84.00, 32.00, 300),
    ('prod_accessories_07', 'Polarized Sunglasses', 'accessories', 'ACC-SUN-007', 58.00, 19.00, 560),
    ('prod_accessories_09', 'Black Tote Bag', 'accessories', 'ACC-TOT-009', 42.00, 14.50, 480)
]) AS product
SELECT
    tupleElement(product, 1) AS product_id,
    tupleElement(product, 2) AS product_name,
    toLowCardinality(tupleElement(product, 3)) AS category,
    tupleElement(product, 4) AS sku,
    toDecimal64(tupleElement(product, 5), 2) AS list_price,
    toDecimal64(tupleElement(product, 6), 2) AS unit_cogs,
    toUInt32(tupleElement(product, 7)) AS inventory_on_hand,
    toUInt8(1) AS is_active,
    multiIf(
        tupleElement(product, 1) = 'prod_shoes_04', toDate('2026-03-10'),
        tupleElement(product, 3) = 'shoes', toDate('2024-03-01'),
        tupleElement(product, 3) = 'accessories', toDate('2024-05-15'),
        tupleElement(product, 3) = 'pants', toDate('2023-09-01'),
        toDate('2023-06-01')
    ) AS launch_date
