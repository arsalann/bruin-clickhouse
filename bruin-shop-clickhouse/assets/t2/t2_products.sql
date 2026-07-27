/* @bruin
name: bruin_shop.t2_products
type: clickhouse.sql
description: "Conformed T2 product dimension with catalog margin and current inventory value."
materialization:
  type: table
  strategy: create+replace
depends:
  - bruin_shop.t1_products

tags:
  - t2
  - conformed
domains:
  - commerce
meta:
  grain: one row per product
  source_system: conformed_shopify

custom_checks:
  - name: preserves the product catalog
    description: Ensures every source product appears exactly once.
    query: |
      SELECT
        (SELECT count() FROM bruin_shop.t2_products)
        =
        (SELECT count() FROM bruin_shop.t1_products)
    value: 1
    blocking: true

unit_tests:
  - name: calculates catalog margin and inventory value
    inputs:
      - asset: bruin_shop.t1_products
        rows:
          - {product_id: "prod_test", product_name: "Test Product", category: "accessories", sku: "TEST-1", list_price: 40, unit_cogs: 12, inventory_on_hand: 70, is_active: 1, launch_date: "2025-01-01"}
    expected:
      count: 1
      rows:
        - {product_id: "prod_test", gross_margin_pct: 0.7, inventory_carrying_value: 840}

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
  - name: gross_margin_pct
    type: Float64
    description: "Catalog unit margin divided by list price."
    checks:
      - name: min
        value: 0
      - name: max
        value: 1
  - name: inventory_on_hand
    type: UInt32
    description: "Current synthetic sellable inventory units."
    checks:
      - name: non_negative
  - name: inventory_carrying_value
    type: Decimal(18, 2)
    description: "Current inventory quantity valued at standard unit cost."
    checks:
      - name: non_negative
  - name: is_active
    type: UInt8
    description: "Whether the product is active in the catalog."
  - name: launch_date
    type: Date
    description: "Date on which the product launched."
@bruin */

SELECT
    product_id,
    product_name,
    category,
    sku,
    list_price,
    unit_cogs,
    round(
        if(list_price = 0, 0, toFloat64(list_price - unit_cogs) / toFloat64(list_price)),
        4
    ) AS gross_margin_pct,
    inventory_on_hand,
    toDecimal64(toDecimal64(inventory_on_hand, 2) * unit_cogs, 2) AS inventory_carrying_value,
    is_active,
    launch_date
FROM bruin_shop.t1_products
