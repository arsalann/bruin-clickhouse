# Bruin Shop ClickHouse

A self-contained Shopify analytics warehouse showcase built with Bruin and ClickHouse. It models the data contracts and operating patterns of a small direct-to-consumer shop without requiring external credentials.

The source layer is deliberately synthetic. It generates deterministic, non-personal data shaped like Shopify, Stripe, GA4, Google Ads, and Meta Ads records. The downstream layers are production-style SQL models and can be retained when the synthetic assets are replaced with real Bruin `ingestr` assets.

## What the pipeline covers

- Shopify-style customers, products, order headers, and normalized order lines.
- Stripe-style payment intents and full or partial refunds.
- GA4-style daily web funnels across five acquisition channels.
- Google Ads and Meta Ads-style paid-media delivery and spend.
- Geography, inventory, lifecycle, cohort, product, reconciliation, and event-impact analysis.
- Eight deterministic scenarios: campaign wins and failures, an outage, a product defect, a launch, and a stockout.

All generated email addresses use the reserved `demo-shop.example` domain. No source row contains real customer or credential data.

## Architecture

```text
T1 source contracts
markets ─┬─> customers ───────────────────────────────┐
         ├─> paid media ─> web sessions ─> order lines ─> orders
events ──┘                         products ───────────┘      │
                                                             ├─> payment intents
                                                             └─> refunds

T2 conformed models
orders + payments + refunds ─> conformed orders ─┬─> customers
order lines + conformed orders ─> conformed lines ├─> web attribution
products ─> conformed products                    └─> downstream marts
paid media ─> conformed paid media

T3 analytical marts
daily revenue ─> daily KPIs
marketing ROI | customer cohorts | product performance
payment reconciliation | special-event impact
```

### T1: source contracts

T1 represents what would normally land from operational systems. Dimensions are reproducible snapshots; dated facts are regenerated only for the requested run interval.

- `t1_markets`, `t1_products`, and `t1_special_events` provide reference data.
- `t1_customers` supplies 120,000 deterministic customer profiles with valid signup timing.
- `t1_marketing_spend` contains only paid search and paid social delivery.
- `t1_web_sessions` contains paid and non-paid funnel activity.
- `t1_order_line_items` is the normalized basket grain; orders can contain one to three product lines.
- `t1_orders` aggregates line items into unique Shopify-style order headers.
- `t1_payment_intents` and `t1_refunds` provide payment-provider-style financial records.

### T2: conformed models

T2 standardizes source records and applies shared business rules.

- A successful order means payment was captured and the order was not cancelled. A later full refund does not erase the original conversion.
- Refunds are allocated proportionally to order lines, with the final line absorbing any rounding residual.
- Net revenue is captured order value less refunds.
- Gross profit is net revenue less recognized product cost.
- Contribution margin is gross profit less fulfillment and payment-processing costs. It is intentionally before paid-media spend.
- Customer acquisition channel is the first successfully captured order channel; profile signup channel remains a separate field.

### T3: analytical marts

T3 exposes stable reporting grains for dashboards and analysis.

- Daily commerce and executive KPIs.
- Paid-media ROI and customer-acquisition cost by date, market, and paid channel.
- Monthly first-order cohorts and retention.
- Product sales, allocated refunds, realized margin, and inventory context.
- Daily order/payment/refund reconciliation.
- Event-period results against the preceding 14-day baseline. Product-specific events scope orders to baskets containing that product.

## Materialization and physical design

Bruin manages all refresh behavior; there are no hand-written delete helpers.

| Assets | Materialization | Refresh behavior |
|---|---|---|
| T1 reference/customer snapshots | `table / create+replace` | Rebuild complete deterministic snapshot |
| T1 dated source facts | `table / time_interval` | Replace only requested source dates |
| T2 customer/product snapshots | `table / create+replace` | Recompute complete conformed dimension |
| T2 dated facts | `table / time_interval` | Replace only requested business dates |
| T3 cohort/product/event marts | `table / create+replace` | Recompute small all-history summary |
| T3 daily/marketing/reconciliation marts | `table / time_interval` | Replace only requested reporting dates |

The demo tables are intentionally unpartitioned: the complete warehouse is only tens of megabytes, and ClickHouse partitions are primarily a data-lifecycle feature rather than a substitute for the sparse primary-key index. Dated-fact identifiers begin with or derive from time, so their sorting keys still follow the dominant date access pattern. Add monthly partitions only when retention operations or materially larger volumes justify them, and verify that the installed Bruin version renders the desired ClickHouse DDL. Monetary values use `Decimal`; bounded categorical columns use `LowCardinality(String)`. The target database is explicitly qualified as `bruin_shop`.

On a normal `time_interval` run, Bruin deletes and reinserts the inclusive date window and adds ClickHouse's rerun-safe insert setting. On `--full-refresh`, Bruin creates or replaces the table from the asset query. See the [Bruin ClickHouse platform guide](https://getbruin.com/docs/bruin/platforms/clickhouse) and [materialization reference](https://getbruin.com/docs/bruin/assets/materialization.html).

## Quality and unit tests

The assets declare their columns, data types, descriptions, primary keys, domains, tags, and grains. Checks cover:

- Not-null, uniqueness, positivity, ranges, and accepted categorical values.
- Funnel ordering, customer signup timing, and product launch timing.
- Order-total, payment-intent, refund, line-allocation, and contribution arithmetic.
- Snapshot population preservation and interval coverage.
- Cohort bounds, reporting grain uniqueness, and event catalog coverage.

Six read-only Bruin unit tests pin the highest-risk transformation logic: partial-refund order economics, line-level refund allocation, first-order attribution, product margin, cohort retention, and daily revenue aggregation.

## Running locally

Commands below assume the repository root, the `default` environment, and a configured `clickhouse-default` connection in the gitignored `.bruin.yml`. Never commit real credentials.

Validate the full DAG:

```bash
bruin validate bruin-shop-clickhouse/pipeline.yml \
  --config-file .bruin.yml \
  --environment default
```

Run read-only unit tests:

```bash
bruin unit-test bruin-shop-clickhouse/pipeline.yml \
  --environment default \
  --start-date 2026-01-01 \
  --end-date 2026-02-28
```

Render one asset:

```bash
bruin render bruin-shop-clickhouse/assets/t3/t3_daily_kpis.sql \
  --config-file .bruin.yml \
  --start-date 2026-06-01 \
  --end-date 2026-06-01
```

Bootstrap or rebuild history from the pipeline start through yesterday:

```bash
bruin run bruin-shop-clickhouse/pipeline.yml \
  --config-file .bruin.yml \
  --environment default \
  --only main \
  --workers 4 \
  --start-date 2025-01-01 \
  --full-refresh
```

Run checks over the same history after a rebuild:

```bash
bruin run bruin-shop-clickhouse/pipeline.yml \
  --config-file .bruin.yml \
  --environment default \
  --only checks \
  --workers 4 \
  --start-date 2025-01-01
```

Run the normal daily pipeline for yesterday, including checks:

```bash
bruin run bruin-shop-clickhouse/pipeline.yml \
  --config-file .bruin.yml \
  --environment default \
  --workers 4
```

Rerun a specific interval safely:

```bash
bruin run bruin-shop-clickhouse/pipeline.yml \
  --config-file .bruin.yml \
  --environment default \
  --workers 4 \
  --start-date 2026-06-01 \
  --end-date 2026-06-07
```

Query a reporting mart:

```bash
bruin query \
  --config-file .bruin.yml \
  --connection clickhouse-default \
  --query "SELECT * FROM bruin_shop.t3_daily_kpis ORDER BY metric_date DESC LIMIT 10" \
  --description "Review recent shop KPIs"
```

## Replacing synthetic sources with live data

Keep the T2 and T3 contracts, then replace the T1 generators with Bruin `ingestr` landing assets and thin normalization models:

| T1 contract | Typical live source |
|---|---|
| Customers | Shopify `customers` |
| Products and inventory | Shopify `products`, `inventory_items` |
| Order headers and lines | Shopify `orders` and nested line items |
| Payment intents and refunds | Stripe `payment_intent`, `refund`, or Shopify `transactions` |
| Web funnel | GA4 `custom` report |
| Paid-media spend | Google Ads daily reports and Meta `facebook_insights` |
| Markets | Shop configuration or maintained seed |
| Special events | Incident and campaign calendar maintained by the business |

Shopify's supported Bruin source tables use primary-key merges, usually on `updated_at`; Shopify `transactions` merges by `id`. Stripe payment and refund tables merge by `id` and `created`. See the [Shopify source reference](https://getbruin.com/docs/ingestr/supported-sources/shopify.html) and [Bruin ingestr asset guide](https://getbruin.com/docs/bruin/assets/ingestr.html).

For live data, also decide explicitly how to handle:

- Store and reporting time zones.
- Presentment versus shop currency and foreign-exchange conversion.
- Taxes, duties, gift cards, shipping refunds, exchanges, and chargebacks.
- Late-arriving order updates and refund lookback windows.
- Customer deletion and privacy requests.
- Attribution identity, window, and model. The showcase uses deterministic same-day last-channel attribution, not causal incrementality.

## Scenario catalog

The fixed 2026 scenarios make the marts useful for demos and regression testing:

| Scenario | Dates | Intended signal |
|---|---|---|
| Paid-search broad-match failure | Jan 12–18 | Spend with weak conversion |
| Checkout outage | Feb 4 | Sessions and conversion collapse |
| Black Tote Bag defect | Feb 20–24 | Elevated partial refunds |
| Trail shoe launch | Mar 10–17 | Paid-social product lift |
| Trail shoe stockout | Mar 18–21 | Product availability collapse |
| Spring outfit campaign | Apr 8–14 | Paid-social lift |
| Memorial Day search | May 11–17 | Paid-search lift |
| Google summer sale | Jun 7–8 | Short paid-search lift |
