# Bruin Shop ClickHouse

This pipeline is a native ClickHouse replication of the ecommerce modeling shape from `/Users/bear/Github/data_playground/bruin-shop`. It is organized into T1 deterministic ecommerce source data, T2 standardized operational facts, and T3 analytical marts for revenue, marketing, cohorts, products, payments, and injected special events.

## Pipeline Graph

### T1

- `t1_markets`: US market dimension used for demand and geography.
- `t1_special_events`: campaign, outage, stockout, and defect scenarios.
- `t1_products`: apparel product catalog with price, COGS, and inventory.
- `t1_customers`: deterministic customer profiles by market.
- `t1_marketing_spend`: daily channel spend, impressions, and clicks.
- `t1_web_sessions`: web funnel activity derived from spend and market demand.
- `t1_orders`: Shopify-style order attempts generated from sessions.
- `t1_payment_intents`: Stripe-style payment records, one per order attempt.
- `t1_refunds`: Stripe-style refund records for refunded orders.

### T2

- `t2_orders`: standardized order fact with payment and refund reconciliation.
- `t2_customers`: customer lifetime metrics and lifecycle segments.
- `t2_products`: active product catalog with gross-margin context.
- `t2_marketing_spend`: normalized marketing spend by channel and market.
- `t2_web_sessions`: web sessions with attributed order and revenue metrics.

### T3

- `t3_daily_revenue`: daily revenue, orders, refunds, COGS, and profit.
- `t3_daily_kpis`: executive daily KPIs across revenue, web, and spend.
- `t3_marketing_roi`: daily channel and market ROI.
- `t3_customer_cohorts`: monthly cohort retention and revenue.
- `t3_product_performance`: catalog sales, refund rate, and inventory value.
- `t3_payment_reconciliation`: Shopify-vs-Stripe reconciliation checks.
- `t3_special_event_impact`: event-window impact against a 14-day baseline.

## Injected Scenarios

The synthetic data includes realistic ecommerce incidents and campaigns:

- Paid search broad-match failure from 2026-01-12 through 2026-01-18.
- Checkout outage on 2026-02-04.
- Black Tote Bag defect refund incident from 2026-02-20 through 2026-02-24.
- Instagram trail shoe launch from 2026-03-10 through 2026-03-17.
- Instagram trail shoe stockout from 2026-03-18 through 2026-03-21.
- Instagram spring outfit campaign from 2026-04-08 through 2026-04-14.
- Google Memorial Day search campaign from 2026-05-11 through 2026-05-17.
- Google summer sale from 2026-06-07 through 2026-06-08.

## Commands

These commands use the real repository Bruin config at `.bruin.yml`. The ClickHouse connection has no default database; every asset and table reference is explicitly scoped to the `bruin_shop` database in the `default` environment.

Validate:

```bash
bruin validate bruin-shop-clickhouse/pipeline.yml \
  --config-file .bruin.yml \
  --environment default \
  --exclude-warnings
```

Render the final KPI mart:

```bash
bruin render bruin-shop-clickhouse/assets/t3/t3_daily_kpis.sql \
  --config-file .bruin.yml \
  --start-date 2026-06-01 \
  --end-date 2026-06-01
```

Bootstrap or restore the historical window:

```bash
bruin run bruin-shop-clickhouse/pipeline.yml \
  --config-file .bruin.yml \
  --environment default \
  --only main \
  --workers 1 \
  --start-date 2025-01-01 \
  --end-date 2026-07-24 \
  --full-refresh
```

Run a normal daily interval:

```bash
bruin run bruin-shop-clickhouse/pipeline.yml \
  --config-file .bruin.yml \
  --environment default \
  --only main \
  --workers 1 \
  --start-date 2026-06-01 \
  --end-date 2026-06-01
```

Run quality checks:

```bash
bruin run bruin-shop-clickhouse/pipeline.yml \
  --config-file .bruin.yml \
  --environment default \
  --only checks \
  --workers 1 \
  --start-date 2026-01-01 \
  --end-date 2026-06-30
```

Query the final marts:

```bash
bruin query \
  --config-file .bruin.yml \
  --environment default \
  --connection clickhouse-default \
  --query "select * from bruin_shop.t3_daily_kpis order by metric_date desc limit 10"
```

## Incremental Behavior

The daily date-grained assets use Bruin's `{{ start_date }}` and `{{ end_date }}` variables directly. Normal runs replace only the requested interval instead of recreating the full history:

- Date-grained T1, T2, and T3 tables use `append`.
- Each append asset depends on a matching `*_delete_interval` helper.
- Each helper runs `ALTER TABLE ... DELETE WHERE <date column> BETWEEN {{ start_date }} AND {{ end_date }} SETTINGS mutations_sync = 2`.
- Append queries end with `SETTINGS insert_deduplicate = 0` so rerunning the same deterministic interval inserts the replacement rows after the delete.
- Small full-table summary and dimension-like assets use `truncate+insert`.

The bootstrap command should be a `--full-refresh` run so Bruin creates the target tables before interval helpers are needed. After bootstrap, daily runs can be rerun safely for the same date or a wider date window.

Refund records are generated from orders and are incrementally keyed by the originating `order_date`; `refund_created_at` can fall 1-10 days later. This keeps revenue and payment reconciliation reports aligned to Shopify order dates.
