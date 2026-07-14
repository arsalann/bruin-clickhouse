/* @bruin
name: shop_raw_products
type: clickhouse.sql
materialization:
   type: table

columns:
  - name: product_id
    type: varchar
    primary_key: true
    checks:
        - name: not_null
        - name: unique
  - name: product_name
    type: varchar
  - name: category
    type: varchar
  - name: sku
    type: varchar
  - name: list_price
    type: float
  - name: unit_cogs
    type: float
  - name: inventory_on_hand
    type: integer
  - name: is_active
    type: integer
  - name: launch_date
    type: date
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
    tupleElement(product, 3) AS category,
    tupleElement(product, 4) AS sku,
    toFloat64(tupleElement(product, 5)) AS list_price,
    toFloat64(tupleElement(product, 6)) AS unit_cogs,
    toUInt32(tupleElement(product, 7)) AS inventory_on_hand,
    1 AS is_active,
    multiIf(tupleElement(product, 3) = 'shoes', toDate('2025-11-01'), tupleElement(product, 3) = 'accessories', toDate('2025-09-15'), toDate('2025-08-01')) AS launch_date
