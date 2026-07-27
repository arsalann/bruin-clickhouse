/* @bruin
name: bruin_shop.t2_products
type: clickhouse.sql
description: "T2 active product dimension enriched with gross-margin and inventory-value metrics."
materialization:
   type: table
   strategy: truncate+insert
depends:
    - bruin_shop.t1_products

custom_checks:
  - name: contains rows
    description: Ensures the materialized table is not empty.
    query: SELECT count() > 0 FROM bruin_shop.t2_products
    value: 1
    blocking: true
columns:
  - name: product_id
    type: varchar
    description: "Stable identifier of the product."
    primary_key: true
    checks:
        - name: not_null
        - name: unique
  - name: product_name
    type: varchar
    description: "Display name of the product."
  - name: category
    type: varchar
    description: "Merchandise category assigned to the product."
  - name: sku
    type: varchar
    description: "Stock-keeping unit assigned to the product."
  - name: list_price
    type: float
    description: "Catalog list price per product unit."
    checks:
      - name: positive
  - name: unit_cogs
    type: float
    description: "Cost of goods sold per product unit."
    checks:
      - name: non_negative
  - name: gross_margin_pct
    type: float
    description: "Gross profit as a percentage of net revenue."
  - name: inventory_on_hand
    type: integer
    description: "Current sellable units available in inventory."
    checks:
      - name: non_negative
  - name: inventory_carrying_value
    type: float
    description: "Current inventory quantity valued at unit cost."
    checks:
      - name: non_negative
  - name: is_active
    type: integer
    description: "Whether the product is active in the catalog."
  - name: launch_date
    type: date
    description: "Date on which the product was launched."
@bruin */

SELECT
    product_id,
    product_name,
    category,
    sku,
    list_price,
    unit_cogs,
    round((list_price - unit_cogs) / list_price, 4) AS gross_margin_pct,
    inventory_on_hand,
    round(inventory_on_hand * unit_cogs, 2) AS inventory_carrying_value,
    is_active,
    launch_date
FROM bruin_shop.t1_products
