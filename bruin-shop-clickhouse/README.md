# Bruin Shop ClickHouse

A live Shopify analytics pipeline built with Bruin, ingestr, and ClickHouse. The pipeline reads the `shopify` connection from the gitignored `.bruin.yml`, lands the shop's available Admin API data, and builds conformed commerce models and reporting marts.

The default historical horizon begins on `2006-01-01`. All timestamps and reporting dates are modeled in UTC. Monetary values stay in Shopify shop currency; the pipeline never silently converts or combines currencies.

## Available Shopify data

The T1 layer ingests every Shopify resource exposed successfully by this shop connection:

| Asset | Shopify resource | Incremental cursor | Primary key | Current purpose |
|---|---|---|---|---|
| `t1_customers` | `customers` | `updated_at` | `id` | Customer lifecycle and consent |
| `t1_products` | `products` | `updated_at` | `id` | Catalog and variant price range |
| `t1_orders` | `orders` | `updated_at` | `id` | Orders, nested lines, refunds, and addresses |
| `t1_inventory_items` | `inventory_items` | `updated_at` | `id` | Variant inventory, quantities, and current cost |
| `t1_discounts` | `discounts` | `updated_at` | `id` | Raw discount definitions |
| `t1_events` | `events` | `created_at` | `id` | Raw Shopify administrative events |

Shopify Payments `transactions` and `balance` were tested through the same connector and returned HTTP 404 for this shop. They are therefore not declared as assets. `t3_payment_reconciliation` is explicitly an order financial-status reconciliation, not a gateway settlement or payout ledger.

There are no SQL seed generators and no non-Shopify source assets in this pipeline.

## Architecture

```text
Shopify via ingestr
customers  products  orders  inventory_items  discounts  events
    │          │       │            │
    └──────────┼───────┼────────────┘
               ▼
T2 conformed models
customers  products  orders  order_line_items  inventory_items
               │       │          │
               └───────┴──────────┘
                       ▼
T3 marts
daily_revenue ──> daily_kpis
payment_reconciliation
customer_cohorts
product_performance
```

### Business rules

- A completed order has financial status `paid`, `partially_refunded`, or `refunded` and is neither a test nor cancelled.
- Recognized order revenue uses Shopify's current order total for completed orders.
- Recognized product revenue uses the current merchandise subtotal, allocated proportionally across original net line values. This incorporates order-level returns and refunds without inventing line-refund facts.
- Customer lifecycle and cohorts use completed orders only. Guest orders are excluded from identified-customer metrics.
- Product performance does not estimate historical COGS or profit. Shopify exposes current inventory-item cost, not the cost captured when an order was placed.
- Direct customer identifiers and postal addresses remain in restricted T1 data. T2 omits names, email addresses, phone numbers, notes, and street addresses.

## Incremental and physical design

| Asset group | Strategy | Behavior |
|---|---|---|
| T1 Shopify assets | `merge` | Pull records changed in the run interval and merge on Shopify ID |
| T2 conformed assets | `merge` | Rebuild changed entities; dependent customer/product rows also refresh when orders or inventory change |
| T3 daily marts | `merge` | Recompute complete date-currency groups touched by changed orders |
| T3 customer cohorts | `create+replace` | Atomically rebuild the compact all-history cohort summary |
| T3 product performance | `create+replace` | Atomically rebuild the compact current-catalog plus lifetime-sales summary |

All interval-aware SQL assets apply the requested timestamps in both incremental and full-refresh mode. Because a full refresh replaces its target, it must be run with the complete historical interval beginning at the pipeline horizon (`2006-01-01`); the bootstrap command below does this explicitly.

Natural Shopify identifiers are primary keys for dimensions. Order and line fact keys begin with the UTC order date, and daily mart keys begin with the reporting date; these become ClickHouse sorting keys and support the dominant access paths. Currency is included in reporting keys wherever values are aggregated.

The tables are deliberately unpartitioned at the shop's current scale. Small partitions would add metadata and merge overhead without improving retention management. Add monthly partitions only after table size, retention operations, or measured query behavior justify them. The two all-history marts use `create+replace` because they are compact and historically dependent; the larger entity and daily tables use merges.

`t1_orders` enforces its raw schema and lands API money fields as strings before T2 converts them to `Decimal(18, 2)`. This avoids lossy inference and decimal schema-evolution failures while preserving the exact Shopify payload.

## Quality contracts

Every asset declares a description, tags, domains, grain, source metadata, and descriptions for all output columns. Blocking checks cover:

- Primary-key nullability and uniqueness.
- Raw-to-conformed customer and product preservation.
- Order and line-total reconciliation.
- Refund-aware line revenue allocation.
- Currency consistency between catalog and completed order lines.
- Daily recognized-revenue and financial-status reconciliation.
- Customer cohort chronology and retention bounds.
- Accepted status bands and non-negative monetary measures.

## Running locally

Commands assume the repository root, the `default` environment, a `shopify` source connection, and a `clickhouse-default` destination connection in `.bruin.yml`. Do not commit credentials.

Validate the complete DAG:

```bash
bruin validate bruin-shop-clickhouse/pipeline.yml \
  --config-file .bruin.yml \
  --environment default
```

Render an incremental asset query:

```bash
bruin render bruin-shop-clickhouse/assets/t3/t3_daily_kpis.sql \
  --config-file .bruin.yml \
  --start-date 2026-04-27 \
  --end-date 2026-04-27
```

Bootstrap or fully rebuild Shopify history. Replace `YYYY-MM-DD` with yesterday's UTC date:

```bash
bruin run bruin-shop-clickhouse/pipeline.yml \
  --config-file .bruin.yml \
  --environment default \
  --only main \
  --workers 4 \
  --full-refresh \
  --start-date "2006-01-01 00:00:00" \
  --end-date "YYYY-MM-DD 23:59:59.999999"
```

Run all checks after the rebuild over the same interval:

```bash
bruin run bruin-shop-clickhouse/pipeline.yml \
  --config-file .bruin.yml \
  --environment default \
  --only checks \
  --workers 4 \
  --start-date "2006-01-01 00:00:00" \
  --end-date "YYYY-MM-DD 23:59:59.999999"
```

Run the normal incremental pipeline for yesterday, including checks:

```bash
bruin run bruin-shop-clickhouse/pipeline.yml \
  --config-file .bruin.yml \
  --environment default \
  --workers 4
```

Rerun a known change interval safely:

```bash
bruin run bruin-shop-clickhouse/pipeline.yml \
  --config-file .bruin.yml \
  --environment default \
  --workers 4 \
  --start-date "2026-04-27 00:00:00" \
  --end-date "2026-04-27 23:59:59.999999"
```

Query the reporting layer:

```bash
bruin query \
  --config-file .bruin.yml \
  --environment default \
  --connection clickhouse-default \
  --query "SELECT * FROM bruin_shop.t3_daily_kpis ORDER BY metric_date DESC LIMIT 10" \
  --description "Review recent Shopify KPIs"
```
