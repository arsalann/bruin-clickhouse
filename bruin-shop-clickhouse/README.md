# Bruin Shop ClickHouse

This pipeline is a native ClickHouse replication of the ecommerce modeling shape from `/Users/bear/Github/data_playground/bruin-shop`. It keeps the same end-to-end structure: deterministic raw ecommerce source data, staging models that standardize the operational facts, and report marts for revenue, marketing, cohorts, products, payments, and injected special events.

## Pipeline Graph

### Raw

- `shop_raw_markets`: US market dimension used for demand and geography.
- `shop_raw_special_events`: campaign, outage, stockout, and defect scenarios.
- `shop_raw_products`: apparel product catalog with price, COGS, and inventory.
- `shop_raw_customers`: deterministic customer profiles by market.
- `shop_raw_marketing_spend`: daily channel spend, impressions, and clicks.
- `shop_raw_web_sessions`: web funnel activity derived from spend and market demand.
- `shop_raw_orders`: Shopify-style order attempts generated from sessions.
- `shop_raw_payment_intents`: Stripe-style payment records, one per order attempt.
- `shop_raw_refunds`: Stripe-style refund records for refunded orders.

### Staging

- `shop_stg_orders`: standardized order fact with payment and refund reconciliation.
- `shop_stg_customers`: customer lifetime metrics and lifecycle segments.
- `shop_stg_products`: active product catalog with gross-margin context.
- `shop_stg_marketing_spend`: normalized marketing spend by channel and market.
- `shop_stg_web_sessions`: web sessions with attributed order and revenue metrics.

### Reports

- `shop_rpt_daily_revenue`: daily revenue, orders, refunds, COGS, and profit.
- `shop_rpt_daily_kpis`: executive daily KPIs across revenue, web, and spend.
- `shop_rpt_marketing_roi`: daily channel and market ROI.
- `shop_rpt_customer_cohorts`: monthly cohort retention and revenue.
- `shop_rpt_product_performance`: catalog sales, refund rate, and inventory value.
- `shop_rpt_payment_reconciliation`: Shopify-vs-Stripe reconciliation checks.
- `shop_rpt_special_event_impact`: event-window impact against a 14-day baseline.

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

These commands use the real repository Bruin config at `.bruin.yml`, which points `clickhouse-default` at the configured ClickHouse Cloud connection in the `default` environment.

Validate:

```bash
bruin validate bruin-shop-clickhouse --config-file .bruin.yml --environment default
```

Render the final KPI mart:

```bash
bruin render bruin-shop-clickhouse/assets/reports/shop_rpt_daily_kpis.sql --config-file .bruin.yml
```

Run end to end:

```bash
bruin run bruin-shop-clickhouse/pipeline.yml --config-file .bruin.yml --environment default
```

Query the final marts:

```bash
bruin query \
  --config-file .bruin.yml \
  --environment default \
  --connection clickhouse-default \
  --query "select * from shop_rpt_daily_kpis order by metric_date desc limit 10"
```
