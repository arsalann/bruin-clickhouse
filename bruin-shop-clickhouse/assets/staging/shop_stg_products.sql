/* @bruin
name: shop_stg_products
type: clickhouse.sql
materialization:
   type: table
depends:
    - shop_raw_products

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
  - name: gross_margin_pct
    type: float
  - name: inventory_on_hand
    type: integer
  - name: inventory_carrying_value
    type: float
  - name: is_active
    type: integer
  - name: launch_date
    type: date
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
FROM shop_raw_products
