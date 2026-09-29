# Requirements — Template F: Programmatic AdTech Analytics on ClickHouse

| | |
|---|---|
| **Status** | Draft for review |
| **Owner** | Arsalan (arsalan.noorafkan@getbruin.com) |
| **Date** | 2026-08-18 |
| **Industry** | AdTech — programmatic advertising (DSP / retail-media / performance marketing) |
| **Use case** | Log-level delivery analytics + cross-channel spend, attribution, pacing, and reconciliation |
| **Sources** | S3/GCS log-level event feeds · **Kafka event topics** · ad-platform APIs (Google/Meta/TikTok/LinkedIn/Reddit Ads) · MMP (Adjust/AppsFlyer) · GA4 · Frankfurter FX · seed CSV dimensions |
| **Destination** | ClickHouse |
| **Visualization** | Bruin **DAC** (Dashboard-as-Code) — 3 personas |
| **Cadence** | Two pipelines: **every 15 min** (delivery plane) + **daily** (spend plane) |
| **Demo data** | **Python seed generator** (full synthetic auction funnel) — fully offline |
| **Target repo** | `bruin-clickhouse` showcase |
| **Proposed dirs** | `bruin-adtech-clickhouse/`, `bruin-adtech-spend-clickhouse/` |
| **CH schema** | `bruin_adtech` |
| **Related** | `bruin-clickhouse-101` (mechanics), `bruin-shop-clickhouse` (batch medallion), [`payments-clickhouse-requirements.md`](./payments-clickhouse-requirements.md) (Template A) |

---

## 1. Summary

AdTech is the vertical ClickHouse was effectively built for: trillions of auction events a day,
sub-second advertiser-facing reporting, and every metric sliced by a dozen high-cardinality
dimensions. It is also the vertical where the *data engineering* is hardest — conversions arrive
days after the impression they belong to, ad platforms silently restate spend for a week, every
channel reports in a different currency, timezone, and schema, and the log-level truth never
matches the platform's invoice.

This template builds a **programmatic ad platform's analytics warehouse** on ClickHouse, with
Bruin owning the entire path:

- **Delivery plane (every 15 min)** — log-level auction/impression/click/conversion feeds land
  from object storage **or a Kafka topic** (two interchangeable ingestion paths onto the same DAG),
  are deduped and enriched, then folded into multi-grain rollups powering a live **trader ops**
  dashboard: win rate, clearing price, budget pacing, loss reasons, IVT.
- **Spend plane (daily)** — five ad-platform APIs plus an MMP, GA4, and FX rates are ingested via
  **ingestr**, normalized into one channel-agnostic spend fact, and blended with owned conversions
  into an **advertiser-facing** performance report.
- **Reconciliation & attribution** — the two planes meet: multi-touch attribution over a
  user-level touchpoint stream (`ASOF JOIN`), reach & frequency (`uniqCombined`), funnel conversion
  (`windowFunnel`), and a **discrepancy mart** that quantifies log-level vs. platform-reported
  drift — the single most-requested report in adtech that no BI tool ships out of the box.

Where Template A (payments) demonstrates *CDC → rollup → serving*, this template demonstrates
**many-source ingestion → conformance → attribution → reconciliation → multi-persona serving**, at
event volumes and cardinalities that make ClickHouse's engine features load-bearing rather than
decorative.

---

## 2. Industry primer — how adtech data actually works

A requirements doc for this vertical is only credible if it models the real funnel and the real
pain. Both are summarized here so the build does not have to re-derive them.

### 2.1 The programmatic funnel

```
  bid request  ──▶  bid response  ──▶  auction win  ──▶  impression  ──▶  click  ──▶  conversion
  (10^12/day)      (bid or no-bid)     (clearing price)   (billable?)     (~0.1%)     (hours–days later)
       │                  │                   │                │                          │
   exchange/SSP      our bidder          second-price      viewability +            attributed back to
   floor, deal_id    price, timeout      or first-price     IVT filtering           a touchpoint by us
```

Each stage drops 2–4 orders of magnitude, so **every stage needs its own fact table and its own
grain** — you cannot answer "why did win rate fall" from impression data alone.

### 2.2 The actors and their data

| Actor | Emits | Typical delivery |
|---|---|---|
| **SSP / exchange** (PubMatic, Magnite, Index, OpenX, AdX) | bid requests, floors, loss reasons | log-level feed → S3/GCS, hourly Parquet/JSONL |
| **DSP / bidder** (our platform) | bid responses, wins, clearing price | own event stream (Kafka → object storage) |
| **Ad server / tracker** | impressions, clicks, viewability beacons | log-level feed, duplicated by retries |
| **Walled gardens** (Google, Meta, TikTok, LinkedIn, Reddit Ads) | aggregated campaign reports only | REST API, **restated for 3–7 days**, account currency + account timezone |
| **MMP** (AppsFlyer, Adjust) | mobile installs + in-app events, their own attribution | REST API |
| **Web analytics** (GA4, Mixpanel, PostHog) | on-site behavior, sessions | REST API |
| **Verification** (IAS, DoubleVerify, HUMAN) | IVT / brand-safety / viewability flags | joined onto impressions |

The structural asymmetry matters: **owned inventory gives log-level rows, walled gardens give only
daily aggregates.** Any real adtech warehouse must model both and reconcile them. This template
does exactly that, which is also why it exercises far more of Bruin than a single-source pipeline.

### 2.3 The twelve hard data problems (all are in scope — see §11)

1. **Late-arriving conversions** — a purchase today may attribute to an impression 30 days ago.
   Yesterday's "final" ROAS is never final.
2. **Platform restatement** — Google/Meta revise spend and conversions for ~3–7 days after the
   fact; naive `append` double-counts, naive `create+replace` is unaffordable.
3. **Log-level vs. platform discrepancy** — 2–10% impression/spend drift is normal; >10% is an
   incident. Advertisers demand the number.
4. **Multi-currency** — spend arrives in each ad account's currency; reporting is one currency.
5. **Multi-timezone** — platform "days" are in the *account's* timezone; events are UTC. A naive
   join misattributes up to a full day of spend.
6. **Event duplication** — impression and click beacons retry; auction logs are re-delivered.
   Dedup is mandatory before any billable metric.
7. **Identity fragmentation** — cookie deprecation reversed but fragmented: cookies, MAIDs, UID2,
   hashed emails, publisher logins. Reach and frequency are wrong without stitching.
8. **Invalid traffic (IVT)** — bots and spoofed inventory must be excluded from *billable* metrics
   while remaining visible in *gross* metrics.
9. **Cardinality explosion** — `site_domain` × `placement_id` × `creative_id` is millions of
   combinations; the sorting key can only favor one access path.
10. **Non-additive metrics** — unique reach, average frequency, and P95 clearing price cannot be
    summed across rollup grains. The most common source of wrong adtech dashboards.
11. **Mid-flight budget and cap changes** — traders raise, cut, pause, and resume campaigns
    constantly. Pacing joined to a single static budget is silently wrong from the first change
    onward, with no history to explain it.
12. **At-least-once stream delivery** — Kafka replays offsets on consumer restart. Without a dedup
    key on the event ID, every restart inflates billable metrics.

Plus the 2026 context that makes the template feel current: **retail media** networks and **CTV**
are the growth channels (CTV projected to pass \$30B US spend in 2026), **clean rooms** are where
advertiser and publisher data meet, and measurement fragmentation is the top complaint.

**Sources:** [DSP vs SSP guide](https://improvado.io/blog/dsp-vs-ssp-programmatic-guide) ·
[Ad-tech stack explained](https://perform.digital/blogs/ad-tech-stack-explained/) ·
[AdTech trends 2026](https://epom.com/blog/digital-advertising/ad-tech-trends) ·
[CTV trends 2026](https://www.aidigital.com/blog/ctv-advertising-trends) ·
[Clean rooms](https://www.aidigital.com/blog/what-is-a-data-clean-room) ·
[AdTech software guide 2026](https://www.tuvoc.com/blog/adtech-software-development-guide/)

---

## 3. Why AdTech × ClickHouse × Bruin

### 3.1 ClickHouse's position in adtech

- ClickHouse holds the **AWS Advertising & Marketing Technology Competency**, with Braze (3.9T
  messages in 2024), Cognitiv (RTB ML), and Klaviyo cited; the stated workload is "millions of
  events per second, complex attribution queries across billions of datapoints."
- The canonical adtech architecture is explicitly a ClickHouse pattern:
  **Kafka → raw events → materialized views → aggregated tables → reporting API**, with
  `ReplacingMergeTree` for collector-level dedup and `AggregatingMergeTree` for hourly rollups.
- InMobi's migration is the reference performance story: **P99 from >60s to <3s**, ~80% monthly
  cost reduction, 400k+ queries/day.
- AdTech is consistently named the **#1 ClickHouse vertical** alongside finance — which is why
  Template A (fintech) and this template (adtech) together cover the two highest-signal verticals.

**Sources:** [AWS AdTech competency](https://clickhouse.com/blog/achieves-aws-advertising-marketing-technology-competency) ·
[ClickHouse for adtech platforms](https://www.tinybird.co/blog/clickhouse-adtech-platforms) ·
[RTB bid tracking](https://chistadata.com/real-time-bid-tracking-and-optimization-with-clickhouse-in-high-performance-data-pipelines/) ·
[AdTech to Finance](https://www.gocodeo.com/post/clickhouse-use-cases-in-2025-from-ad-tech-to-finance-analytics) ·
[ClickHouse at LifeStreet](https://altinity.com/blog/clickhouse-at-lifestreet-performance-marketing-is-as-strong-as-your-data-platform)

### 3.2 Why this is the strongest Bruin showcase

AdTech is unusually well-matched to Bruin's *breadth* rather than any single feature:

| Adtech reality | Bruin feature it forces you to use |
|---|---|
| 8+ heterogeneous sources | **ingestr** assets across S3, Kafka, 5 ad platforms, MMP, GA4, FX |
| Logs arrive as files *or* as a stream | Two tag-selected ingestion paths onto one unchanged DAG |
| Budgets change mid-flight | Effective-dated seed + `ASOF JOIN` (hand-rolled SCD2) |
| Walled-garden restatement | `merge` + `replacing_merge_tree` + `interval_modifiers` lookback |
| Late conversions (30d window) | `interval_modifiers`, `time_interval`, tiered restatement |
| Two cadences (live vs. daily) | two pipelines + cross-pipeline `uri` dependencies |
| Attribution logic is business-critical | **`bruin unit-test`** on the attribution SQL |
| Discrepancy is an SLA | `custom_checks` with thresholds + `blocking` |
| 3 audiences (trader, advertiser, data-ops) | **DAC** + semantic layer, 3 dashboards, one metric definition |
| No credentials in a demo | Python seed generator + tag-gated live assets |
| Engine features Bruin doesn't model | `hooks.pre` / `hooks.post` raw-SQL escape hatch (§13) |

### 3.3 Fit against existing repo pipelines

| | `bruin-clickhouse-101` | `bruin-shop-clickhouse` | `bruin-payments-clickhouse` | **`bruin-adtech-clickhouse` (this)** |
|---|---|---|---|---|
| Purpose | Feature mechanics | Batch medallion | Real-time rollups | **Many-source conformance + attribution** |
| Sources | Postgres + seed | Shopify | Postgres CDC | **S3 logs / Kafka + 5 ad APIs + MMP + GA4 + FX + seeds** |
| Cadence | Daily | Daily | 1 min | **15 min + daily** |
| Event volume | Trivial | Low | Medium | **High (10–100M rows demo-scale)** |
| CH features | Basic | Basic | RMT, rollups | **Codecs, TTL, skip indexes, projections, dictionaries, funnel/uniq/ASOF** |
| Consumers | Learners | Analysts | Ops | **Traders + advertisers + data-ops** |

---

## 4. Goals / non-goals

### Goals

- Demonstrate **multi-source ingestr ingestion** into ClickHouse: object storage (S3/GCS) log-level
  feeds, **Kafka event topics**, five ad-platform APIs, an MMP, GA4, and an FX-rate API — plus seed
  CSV dimensions.
- Demonstrate **two interchangeable ingestion paths onto one DAG** (object storage vs. Kafka,
  tag-selected), so the batch-vs-stream trade-off is a one-flag switch rather than a slide.
- Demonstrate **effective-dated dimension handling**: mid-flight budget and frequency-cap changes
  joined `ASOF` so pacing and cap-violation math are correct on every date.
- Demonstrate **ClickHouse's signature engine features** where they are genuinely load-bearing:
  `LowCardinality`, column codecs, `TTL` tiering, bloom-filter skip indexes, projections,
  dictionaries, `windowFunnel`, `uniqCombined`, `quantileTDigest`, `ASOF JOIN`, `SAMPLE BY`.
- Demonstrate **correct handling of late-arriving conversions and platform restatement** via
  `interval_modifiers`, `time_interval`, and `merge` — with reconciliation checks proving it.
- Deliver a **channel-normalized spend fact** across five platforms with FX and timezone
  normalization — the single most common real-world marketing-data ask.
- Deliver **attribution** (last-touch + position-based multi-touch) as a first-class, **unit-tested**
  Bruin asset.
- Deliver a **discrepancy mart** quantifying log-level vs. platform-reported drift, with a blocking
  threshold check.
- Deliver **three DAC dashboards** (trader live, advertiser report, data-ops) sharing one semantic
  layer.
- Teach the **additive vs. non-additive metric** trade-off in adtech terms (reach and frequency).
- Run **fully offline** from a Python seed generator; every live asset is tag-gated.

### Non-goals

- Not a bidder. No real-time decisioning, no sub-second serving path — freshness is the 15-minute
  schedule.
- Not a real identity graph. Stitching is a deterministic synthetic mapping, not a probabilistic one.
- Not a clean room. Privacy-safe joins are discussed in the README, not implemented.
- Not an incrementality/MMM model. Attribution is rule-based (last-touch, position-based); no
  causal lift modeling.
- Not real PII. All user keys are synthetic hashes; consent flags are modeled but synthetic.
- Not a *continuous* streaming demo. The Kafka ingestion path **is** built (FR-1b), but Bruin's
  Kafka source is pull-per-run, so freshness stays at the 15-minute schedule. ClickHouse's native
  `Kafka` engine (genuinely continuous) is documented, not built (§13).
- Not a CDC demo. Ad delivery events are immutable logs, so CDC does not apply to them; the campaign
  config plane that *would* use CDC is modeled as an effective-dated seed instead (§5.4.1, O-17).
- Mode 2 (native `AggregatingMergeTree` + trigger MVs) is built **only via the hooks escape hatch**
  in an optional appendix (§13).

---

## 5. Sources of record

### 5.1 Delivery plane — log-level feeds (object storage)

Delivered as hourly-partitioned Parquet, the way SSPs and DSPs actually ship log-level data.

```
s3://bruin-adtech-demo/
├── auctions/dt=2026-08-18/hr=14/part-*.parquet      # bid requests + our bid responses + outcome
├── impressions/dt=.../hr=.../part-*.parquet         # served impressions + viewability + IVT flags
├── clicks/dt=.../hr=.../part-*.parquet
└── conversions/dt=.../hr=.../part-*.parquet         # unattributed; we attribute them
```

**`auctions`** — one row per bid opportunity (the widest, highest-volume feed):

| Field | Type | Notes |
|---|---|---|
| `auction_id` | String | dedup key |
| `event_time` | DateTime64(3,'UTC') | auction time |
| `exchange` | LowCardinality(String) | pubmatic · magnite · index · openx · adx |
| `deal_id` | Nullable(String) | PMP/PG deal, null for open market |
| `publisher_id`, `site_domain`, `app_bundle` | String | **high cardinality** → bloom filter |
| `placement_id` | String | high cardinality |
| `ad_format` | LowCardinality(String) | banner · video · native · **ctv** · audio |
| `video_position` | LowCardinality(String) | preroll · midroll · postroll · n/a |
| `device_type`, `os`, `browser` | LowCardinality(String) | mobile · desktop · tablet · ctv |
| `country`, `region`, `dma` | LowCardinality(String) | |
| `user_key` | String | cookie / MAID / UID2 / hashed-email (prefixed by type) |
| `gdpr_applies`, `us_privacy`, `consent_ok` | UInt8 / String | consent modeled, honored in reach |
| `advertiser_id`, `campaign_id`, `line_item_id`, `creative_id` | UInt32/String | |
| `floor_price_cpm`, `bid_price_cpm`, `win_price_cpm` | Decimal(12,4) | clearing price on win |
| `bid_status` | LowCardinality(String) | no_bid · bid_lost · bid_won · timeout · filtered |
| `loss_reason` | LowCardinality(String) | below_floor · outbid · creative_rejected · timeout · … |
| `currency` | LowCardinality(String) | |

**`impressions`** — `impression_id`, `auction_id`, `event_time`, `billable`, `viewability_measured`,
`viewable`, `ivt_flag`, `ivt_category` (gitvt/sivt/none), `media_cost_cpm`, `data_cost_cpm`,
`advertiser_revenue`, `currency`.
**`clicks`** — `click_id`, `impression_id`, `auction_id`, `user_key`, `event_time`.
**`conversions`** — `conversion_id`, `user_key`, `event_time`, `conversion_type`
(purchase · signup · install · add_to_cart), `order_value`, `currency`, `advertiser_id`.
Deliberately **carries no attribution** — attributing it is the pipeline's job.

### 5.2 Delivery plane — Kafka topics (the streaming path)

The same four event streams, delivered as Kafka topics rather than object-storage batches. This is
the **canonical adtech ingestion architecture** (§3.1: Kafka → raw events → aggregates), so the
template must be able to actually run it, not just describe it.

| Topic | Key | Format |
|---|---|---|
| `adtech.auctions` | `auction_id` | JSON (Avro variant documented) |
| `adtech.impressions` | `impression_id` | JSON |
| `adtech.clicks` | `click_id` | JSON |
| `adtech.conversions` | `conversion_id` | JSON |

- Ingested by **ingestr `kafka` source assets** into the *same* `t1_*_raw` tables as the S3 path —
  identical schema, identical downstream DAG. The two paths are **mutually exclusive and
  tag-selected**, never both in one run.
- Consumer-group offsets provide the incremental cursor, so the strategy is `append` with
  `replacing_merge_tree` dedup absorbing at-least-once redelivery (Kafka gives no exactly-once
  guarantee across a consumer restart — the RMT dedup key is what makes this correct).
- **Local broker:** a `docker-compose.yml` running **Redpanda** (Kafka-API compatible, single
  container, no ZooKeeper) so the streaming path is runnable offline. The Python generator (§5.5)
  gains a `--sink kafka` mode that produces to the topics instead of writing rows directly.
- **Documented, not built:** ClickHouse's native `Kafka` table engine as a third option, and
  `kinesis`/`rabbitmq` as ingestr alternatives.

**Why both paths exist rather than just Kafka:** object storage is what most DSPs and SSPs actually
deliver log-level data as (hourly Parquet drops), and it needs no broker to demo. Kafka is what the
platform's *own* bidder emits and what every ClickHouse adtech reference architecture shows. The
template teaches the trade-off — 15-minute micro-batch vs. continuous — by making it a one-tag switch.

### 5.3 Spend plane — ad-platform APIs (via ingestr)

All confirmed ingestr sources:

| Source | ingestr source | Grain | Restated? |
|---|---|---|---|
| Google Ads | `google_ads` | campaign × day | ✅ ~3 days |
| Facebook/Meta Ads | `facebook_ads` | ad × day | ✅ ~7 days (attribution windows) |
| TikTok Ads | `tiktok_ads` | ad × day | ✅ |
| LinkedIn Ads | `linkedin_ads` | campaign × day | ✅ |
| Reddit Ads | `reddit_ads` | campaign × day | ✅ |
| Adjust **or** AppsFlyer (MMP) | `adjust` / `appsflyer` | install/event × day | ✅ |
| GA4 | `google_analytics` | session/channel × day | partial |
| FX rates | `frankfurter` | currency × day | ❌ (immutable) |

Optional stretch sources also available in ingestr: `applovin`, `applovin_max`, `apple_ads`,
`snapchat_ads`, `pinterest`, `mixpanel`, `posthog`, `braze`, `klaviyo`.

### 5.4 Dimensions — seed assets (CSV)

- `seed_advertisers.csv` — advertiser, vertical, IAB category, home currency
- `seed_campaign_flights.csv` — campaign, line item, flight start/end, **initial budget**, pacing
  goal, KPI type (CPA/ROAS/CPM), target CPA, **frequency cap**
- **`seed_budget_changes.csv`** — effective-dated budget and cap revisions (§5.4.1)
- `seed_creatives.csv` — creative, format, size, landing domain
- `seed_channel_map.csv` — platform account → canonical channel/currency/reporting timezone
- `seed_iab_categories.csv` — category tree for brand-safety grouping
- `seed_inventory_tiers.csv` — domain/app → supply tier (premium/mid/long-tail), SPO path

#### 5.4.1 Mid-flight budget changes (effective-dated)

Campaign budgets are **not** fixed for the life of a flight. Traders raise a budget when a campaign
performs, cut it when it doesn't, and pause/resume campaigns outright. Any pacing calculation that
joins to a single static budget is wrong for every day after the first change — and, worse, silently
wrong, with no history to explain why Tuesday's pacing looked broken.

```csv
change_id,campaign_id,line_item_id,effective_from,daily_budget_usd,total_budget_usd,frequency_cap,status,changed_by,reason
1,1001,20011,2026-08-01,5000.00,150000.00,3,active,trader@example.com,flight_launch
2,1001,20011,2026-08-09,8000.00,190000.00,3,active,trader@example.com,overperforming_raise
3,1001,20011,2026-08-14,8000.00,190000.00,5,active,trader@example.com,cap_relaxed
4,1002,20025,2026-08-12,0.00,60000.00,3,paused,trader@example.com,brand_safety_hold
```

- Grain: one row per `(line_item_id, effective_from)`. Rows are **immutable and append-only**; a
  revision is a new row, never an update. `effective_from` is a date in the reporting timezone.
- The seed generator emits changes for ~30% of line items so the as-of join is genuinely exercised,
  including one **pause-then-resume** (budget → 0 → restored) and one **cap change** so that both
  pacing (FR-7) and frequency-cap violations (FR-8) shift mid-flight.
- Consumed via **`ASOF JOIN`** to get the budget in force on each delivery date (FR-7). This reuses
  the exact join the attribution asset uses (FR-6), which is a nice teaching echo: `ASOF JOIN` is for
  "what was true at this moment", whether the moment is a conversion or a delivery day.
- **In production this table arrives via CDC** from the platform's operational Postgres
  (`campaigns`, `line_items`), since it is a genuine OLTP mutation stream. That is deliberately out
  of scope here — Template A already owns the Postgres-CDC narrative, and a static effective-dated
  seed models the *analytical* consequence identically. See O-17.

### 5.5 Offline demo — Python seed generator

Mandatory. One Python asset family that generates the **entire synthetic funnel**, replacing §5.1,
§5.2 and §5.3 with no external credentials:

- Deterministic (fixed RNG seed) so checks and unit tests are stable.
- Scale via env var: `ADTECH_SCALE=small|medium|large` → ~1M / 10M / 100M auction rows.
- **Two sinks**: `--sink table` writes directly into `t1_*_raw` (default, zero infrastructure), or
  `--sink kafka` produces to the §5.2 topics against the local Redpanda container so the streaming
  ingestion path is exercised end to end.
- Realistic shapes: power-law `site_domain`/`placement_id` distribution, per-exchange win-rate and
  floor distributions, diurnal traffic curve, CTR ~0.08%, CVR ~2% of clicks.
- **Deliberately injects every hard problem from §2.3**: duplicate impression beacons, re-delivered
  auction partitions (and, on the Kafka path, redelivered offsets after a simulated consumer
  restart), conversions lagging 0–30 days, IVT clusters, one bot-like `user_key` with 1000×
  frequency, multi-currency spend, per-account timezone offsets, **mid-flight budget and cap
  changes**, and platform reports whose totals drift 3–8% from the log-level truth *and get restated
  on later runs*.

---

## 6. Architecture

### 6.1 Two pipelines, one warehouse

```
┌─ PIPELINE 1: bruin-adtech-clickhouse ─────────── schedule: */15 * * * * ──────────────────┐
│                                                                                           │
│  S3/GCS log feeds      Kafka topics        Python seed generator (offline)                 │
│   auctions·impressions  adtech.auctions     [tag: offline-demo]                            │
│   clicks·conversions    adtech.impressions   --sink table ─┐  --sink kafka ─┐              │
│        │                adtech.clicks                      │                │              │
│        │ ingestr         adtech.conversions                │                ▼              │
│        │ (s3://,Parquet)      │ ingestr (kafka://)          │        [Redpanda, docker]     │
│        │ [tag:requires-s3]    │ [tag: requires-kafka]       │                │              │
│        │   ── mutually exclusive, tag-selected ──          │                │              │
│        ▼                      ▼                            ▼                ▼              │
│  t1_auctions_raw   t1_impressions_raw   t1_clicks_raw   t1_conversions_raw                 │
│   (append + time_interval; ReplacingMergeTree dedup; TTL 90d)                              │
│        │                                                                                  │
│        │ ② conform + enrich (dictGet campaign/creative; IVT policy; UTC)                   │
│        ▼                                                                                  │
│  t2_auctions   t2_impressions   t2_clicks   t2_conversions   t2_identity_map               │
│        │                                                                                  │
│        ├──▶ t2_touchpoints  (unified user-level ordered event stream — funnel + attribution)│
│        │            │                                                                     │
│        │            ├──▶ t2_attributed_conversions  (ASOF JOIN last-touch + MTA weights)   │
│        │            │       [unit-tested; interval_modifiers: start -30d]                  │
│        ▼            ▼                                                                     │
│  t3_delivery_15m ─▶ t3_delivery_hourly ─▶ t3_delivery_daily     t3_funnel (windowFunnel)   │
│  t3_pacing (ASOF JOIN t2_budget_asof)     t3_reach_frequency (uniqCombined)                │
│  t3_ivt_monitor    t3_inventory_quality (SPO)    t3_creative_performance                   │
│        │                                                                                  │
│        ▼                                                                                  │
│  serving_trader_live  (view: last 24h from 15m rollup ∪ sealed hourly)                     │
│        │                                                                                  │
│        ▼   DAC → trader_live.dashboard                                                     │
└───────────────────────────────────────────────────────────────────────────────────────────┘
                          │  cross-pipeline dependency (uri:)
                          ▼
┌─ PIPELINE 2: bruin-adtech-spend-clickhouse ───── schedule: @daily ────────────────────────┐
│                                                                                           │
│  Google Ads  Meta Ads  TikTok Ads  LinkedIn Ads  Reddit Ads   Adjust/AppsFlyer   GA4       │
│      │           │          │           │            │              │            │        │
│      └───────────┴──────────┴───ingestr (merge, per-platform)───────┴────────────┘        │
│                                      │                    Frankfurter FX ──┐               │
│                                      ▼                                     ▼               │
│                       t1_<platform>_report (RMT, restatement-safe)   t1_fx_rates            │
│                                      │                                     │               │
│                                      │ ③ normalize: schema · currency · tz  │               │
│                                      ▼◀────────────────────────────────────┘               │
│                       t2_platform_spend   (one channel-agnostic spend fact)                 │
│                                      │                                                     │
│           ┌──────────────────────────┼─────────────────────────────┐                       │
│           ▼                          ▼                             ▼                       │
│  t3_channel_performance     t3_discrepancy                  t3_advertiser_pnl               │
│  (blended ROAS/CPA/CPM)     (log-level vs platform-reported) (spend + attributed revenue)   │
│           │                          │                             │                       │
│           └──────────────────────────┴─────────────────────────────┘                       │
│                                      ▼                                                     │
│                  serving_advertiser_report (view)   serving_data_ops (view)                 │
│                                      │                                                     │
│                                      ▼  DAC → advertiser_report · data_ops dashboards       │
└───────────────────────────────────────────────────────────────────────────────────────────┘
```

`t3_discrepancy` and `t3_advertiser_pnl` depend on Pipeline 1 tables via `depends: [{ uri: ... }]`;
locally, Pipeline 1 runs first, or a `clickhouse.sensor.table` gates Pipeline 2 (O-8).

### 6.2 Layer contract

| Layer | Rule |
|---|---|
| **t1** | Raw, source-shaped, no business logic. Dedup only. `append` / `time_interval` for events, `merge` for restated API reports. TTL 90d on event tables. |
| **t2** | Conformed and enriched. One canonical schema per concept. All timestamps UTC. All money in reporting currency **and** source currency. IVT policy applied as flags, never by deletion. |
| **t3** | Aggregated marts, one grain per asset, grain declared in `meta`. Additive metrics only; non-additive metrics computed at their own grain from t2. |
| **serving** | Logical views composing t3 for a single dashboard persona. No new logic beyond derived ratios and union of live ∪ sealed. |

### 6.3 Cadence & freshness SLAs

| Asset group | Schedule | Freshness SLA |
|---|---|---|
| t1 event feeds (S3 **or** Kafka) → t3 delivery rollups → trader serving | every 15 min | ≤ 20 min |
| Attribution restatement (7-day tier) | every 15 min | ≤ 30 min |
| Attribution restatement (30-day tier) | daily | ≤ 26 h |
| Platform spend, FX, MMP, GA4 → advertiser serving | daily 06:00 UTC | ≤ 30 h |
| Discrepancy mart | daily | ≤ 30 h |

---

## 7. Metric catalog & additivity

The headline teaching artifact. Every dashboard number must trace to a row here.

| Metric | Definition | Additive across grains? | Computed at |
|---|---|---|---|
| Bid requests | `count()` auctions | ✅ | t3_delivery_15m |
| Bid rate | bids / bid requests | ➗ ratio of additive parts | serving (derived) |
| **Win rate** | wins / bids | ➗ ratio of additive parts | serving (derived) |
| Impressions (gross) | `count()` impressions | ✅ | t3_delivery_15m |
| Impressions (billable) | `countIf(billable AND ivt_flag = 0)` | ✅ | t3_delivery_15m |
| Media spend | `sum(win_price_cpm)/1000` | ✅ | t3_delivery_15m |
| Advertiser revenue | `sum(advertiser_revenue)` | ✅ | t3_delivery_15m |
| Clicks / CTR | count / clicks÷impressions | ✅ / ➗ | t3 / serving |
| Conversions / CVR | attributed count / ÷clicks | ✅ / ➗ | t3_attribution_daily |
| eCPM / eCPC / eCPA | spend ÷ (imps/1000 · clicks · convs) | ➗ | serving |
| ROAS | attributed revenue ÷ spend | ➗ | serving |
| Viewability rate | viewable ÷ measured | ➗ | serving |
| IVT rate | ivt ÷ gross impressions | ➗ | serving |
| Pacing index | delivered ÷ (**budget in force, summed over elapsed non-paused days**) | ➗ | t3_pacing |
| **Unique reach** | `uniqCombined(person_key)` | ❌ **not additive** | t3_reach_frequency, per grain |
| **Average frequency** | impressions ÷ unique reach | ❌ depends on reach | t3_reach_frequency |
| **Frequency distribution** | histogram of imps per person | ❌ | t3_reach_frequency |
| **P95 clearing price** | `quantileTDigest(0.95)(win_price_cpm)` | ❌ **not additive** | t3_delivery_hourly, per grain |
| **Funnel conversion** | `windowFunnel(30d)(...)` | ❌ path-dependent | t3_funnel |
| **Multi-touch credit** | position-based weights over touchpoint path | ❌ path-dependent | t2_attributed_conversions |
| Discrepancy % | (platform − log-level) ÷ platform | ➗ | t3_discrepancy |

**Standard dimension set** for additive metrics: `advertiser_id`, `campaign_id`, `line_item_id`,
`creative_id`, `channel`, `exchange`, `ad_format`, `device_type`, `country`, `supply_tier`,
`deal_type`.

**Rule enforced by `custom_checks`:** no non-additive metric may appear in an asset whose grain is
coarser than where it was computed.

---

## 8. Functional requirements

### FR-1 — Log-level event ingestion (ingestr, object storage)
- Four `ingestr` YAML assets reading hourly-partitioned Parquet from `s3://` (GCS variant
  documented), into `t1_*_raw`.
- Strategy `time_interval` on `event_time` (hour granularity) so a re-run of an hour is idempotent;
  `engine: replacing_merge_tree` with dedup key `auction_id` / `impression_id` / `click_id` /
  `conversion_id` to absorb re-delivered partitions and retried beacons.
- Tagged `requires-s3`; excluded in the offline path.
- `clickhouse.sensor.query` (or `ingestr` source asset) documents/gates arrival of the expected hour
  partition before rollups run.

### FR-1b — Log-level event ingestion (ingestr, Kafka) — the streaming path
- Four `ingestr` YAML assets with a `kafka` source consuming `adtech.{auctions,impressions,clicks,
  conversions}`. Connection params: `bootstrap_servers`, `group_id` (offset tracking), `batch_size`
  (default 3000), `batch_timeout` (default 3s).
- **Kafka lands a fixed two-column schema — `msg_id` + a JSON `data` column — not flattened fields.**
  So the Kafka path needs one extra step the S3 path does not: `t1_*_kafka_raw` (landing) →
  `t1_*_parsed` (ClickHouse `JSONExtract` into the §5.1 typed columns) → then it joins the shared
  `t1_*_raw` contract. Downstream from `t1_*_raw` nothing changes.
  - Upside worth keeping: the raw JSON is retained, so a schema change on the topic doesn't lose
    data — a genuine advantage over the Parquet path, and a good teaching point.
- Strategy `append` (consumer-group offsets are the cursor) with `engine: replacing_merge_tree`
  keyed on `msg_id` at the landing table and on the event ID at `t1_*_parsed`, since Kafka is
  at-least-once and a consumer restart replays offsets. **The dedup key is the correctness
  mechanism here, not an optimization** — call this out in the README.
- **Two modes, and they are not interchangeable:**
  - **Batch (the demo default):** no `stream` flag — each run drains the backlog once and exits.
    This is what fits a 15-minute pipeline schedule.
  - **Continuous (`stream: true` + `flush_interval` / `flush_records`):** the asset consumes
    indefinitely and never exits, so it **cannot** be an asset in a scheduled pipeline. It is a
    long-running process. Documented and demoable standalone, but it is not part of the scheduled
    DAG, and the README must say so plainly rather than implying you get both.
- Tagged `requires-kafka`. FR-1 and FR-1b are **mutually exclusive**: exactly one of
  `requires-s3` / `requires-kafka` / `offline-demo` may be selected per run. A `custom_check`
  asserting no duplicate `auction_id` across ingestion paths guards against running both.
- **Local broker:** `docker-compose.yml` with a single **Redpanda** container (Kafka-API compatible,
  no ZooKeeper), plus a `make kafka-up` / `make kafka-seed` pair that starts it and runs the
  generator in `--sink kafka` mode. Extends the existing local Docker verification setup used
  elsewhere in this repo.
- README documents the three ingestion options and when each applies: object storage (what SSPs
  deliver), Kafka via ingestr (what your own bidder emits), and ClickHouse's native `Kafka` table
  engine (documented, not built — Bruin does not model it, and it moves ownership of ingestion out
  of the DAG, which the README should say plainly).
- Consumer-lag observability: `serving_data_ops` surfaces max event-time lag per topic so the
  streaming path has a freshness signal comparable to the S3 partition sensor.

### FR-2 — Python seed generator (offline demo)
- Python asset(s) generating the full synthetic funnel per §5.5 directly into `t1_*_raw` and
  `t1_<platform>_report`, tagged `offline-demo`.
- Honors `--start-date`/`--end-date` and `BRUIN_FULL_REFRESH` so incremental behavior is realistic.
- Injects duplicates, late conversions, IVT, bot frequency, FX/timezone variance, and
  platform-report drift **and restatement**, so every downstream check has something to catch.
- Scale switch (`ADTECH_SCALE`) with documented row counts and expected runtimes.

### FR-3 — Ad-platform ingestion (ingestr, restatement-safe)
- One `ingestr` asset per platform (Google, Meta, TikTok, LinkedIn, Reddit) + MMP + GA4, each
  `merge` into `t1_<platform>_report` with `engine: replacing_merge_tree`.
- `interval_modifiers: { start: -7d, end: 0h }` (run with `--apply-interval-modifiers`) so each run
  re-pulls the restatement window; documented per platform since windows differ.
- `t1_fx_rates` from `frankfurter`, `append`/`merge` on `(rate_date, base, quote)`; immutable.
- Each live asset tagged `requires-<platform>`; README gives the credential setup and the
  `--exclude-tag` incantation to skip it.

### FR-4 — Seed dimensions & effective-dated budgets
- Seven `seed` assets (§5.4) loading CSV into ClickHouse, with full column descriptions and
  `not_null`/`unique`/`accepted_values` checks.
- `t2_campaign_dim` joins flights + creatives + advertisers; a `hooks.post` creates a ClickHouse
  **dictionary** over it so t2 event assets enrich via `dictGet` instead of a join (§13).
- **`t2_budget_asof`**: flattens `seed_campaign_flights` + `seed_budget_changes` into the
  effective-dated budget/cap timeline per `line_item_id`, one row per
  `(line_item_id, effective_from)`, with `effective_to` computed by `leadInFrame`/`anyOrNull` so each
  row carries a closed validity interval. Checks: no overlapping intervals per line item, exactly one
  open-ended interval per line item, no `effective_from` before flight start, budget ≥ 0.
- Documented as the SCD2-shaped asset the template needs but Bruin cannot express declaratively on
  ClickHouse (`scd2_by_time` is unsupported there) — so it is built by hand as a `create+replace`
  asset over an append-only source. Product-feedback item alongside O-1.

### FR-5 — Conformed event layer (t2)
- `t2_auctions`, `t2_impressions`, `t2_clicks`, `t2_conversions`: UTC timestamps, `dictGet`
  enrichment, canonical `channel`, IVT/viewability policy as flags, money in both source and
  reporting currency (FX joined by `rate_date`).
- `t2_identity_map`: `user_key` → `person_key` deterministic stitch across cookie/MAID/UID2/email
  keys, honoring `consent_ok` (non-consented keys never stitched).
- `t2_touchpoints`: **single unified table** of impressions + clicks ordered by
  `(person_key, event_time)` — the required input for `windowFunnel` and for attribution.
  `SAMPLE BY intHash64(person_key)` for cheap exploratory queries.

### FR-6 — Attribution (the centerpiece)
- `t2_attributed_conversions`: for each conversion, find eligible touchpoints within the configured
  lookback (click 30d, view-through 7d) using **`ASOF JOIN`** on `(person_key, event_time)`.
- Two models emitted side by side: **last-touch** (100% to final touchpoint) and **position-based**
  (40/20/40 across the path), with the touchpoint path retained as an `Array`.
- Both `conversion_date` and `touchpoint_date` retained — advertisers ask for both, and they
  disagree.
- Strategy `merge` keyed on `conversion_id`, with `interval_modifiers: { start: -7d }` on the 15-min
  pipeline and a daily 30-day restatement pass (§6.3), so late conversions correctly rewrite history.
- **`bruin unit-test`** cases: single-touch, multi-touch path, out-of-window touchpoint, conversion
  with no touchpoint, tie on identical timestamps, non-consented user, and a re-run producing
  identical output (idempotence).

### FR-7 — Delivery rollups & pacing
- `t3_delivery_15m` (`time_interval`, `incremental_key: bucket_15m`, RMT) → `t3_delivery_hourly` →
  `t3_delivery_daily`, each a cascade over the previous grain for additive metrics only.
- `t3_delivery_hourly` additionally computes `quantileTDigest` clearing-price percentiles **from t2**
  (non-additive — cannot cascade).
- `t3_pacing`: computes pacing index, projected end-of-flight delivery, and an over/under-delivery
  flag — against the budget **actually in force on each delivery date**, via
  `ASOF JOIN t2_budget_asof` on `(line_item_id, delivery_date >= effective_from)`, *not* a static
  flight budget.
  - Total-budget pacing uses the **sum of daily budgets in force across elapsed days**, so a
    mid-flight raise does not retroactively rewrite yesterday's pacing index.
  - `paused` days (budget 0) are excluded from the elapsed-flight denominator; otherwise a pause
    reads as chronic under-delivery.
  - Emits `budget_change_count` and `current_daily_budget_usd` so the dashboard can annotate the
    pacing chart at each change point — the "why did Tuesday look broken" answer.
  - Checks: pacing index null only when no budget is in force; no delivery date lacking a matching
    budget interval; `delivered_usd` never attributed to a paused day without a warning check.

### FR-8 — Funnel, reach & frequency
- `t3_funnel`: `windowFunnel(30 DAY)(event_time, is_auction, is_win, is_impression, is_click,
  is_conversion)` over `t2_touchpoints` (+ conversions), by campaign and channel; plus a
  `retention()`-style repeat-conversion view.
- `t3_reach_frequency`: `uniqCombined(person_key)` reach per campaign per grain, frequency
  distribution buckets (1, 2, 3–5, 6–10, 11+), average frequency, and **frequency-cap violations**
  against the cap **in force on that date** (`ASOF JOIN t2_budget_asof`, same as FR-7) — a cap
  relaxed from 3 to 5 mid-flight must not retroactively clear prior violations.
- Documented explicitly as non-additive: recomputed at each grain, never summed.

### FR-9 — Quality, inventory & supply-path marts
- `t3_ivt_monitor`: IVT rate by exchange/domain/day, anomalous-CTR detection (CTR > Nx campaign
  median), bot-like frequency outliers, with `blocking: false` alert checks.
- `t3_inventory_quality`: domain/app-level performance by supply tier, viewability, and win-price
  efficiency — the "where is my money going" report.
- `t3_creative_performance`: creative × placement × format, deliberately high-cardinality, backed by
  a **projection** on `(advertiser_id, campaign_id, event_date)` (§13) to show ClickHouse serving a
  second access path.

### FR-10 — Channel normalization & blended performance
- `t2_platform_spend`: `UNION ALL` of all `t1_<platform>_report` assets into one schema
  (`report_date`, `channel`, `account_id`, `campaign_key`, `impressions`, `clicks`, `spend_src`,
  `currency`, `spend_usd`, `platform_conversions`, `platform_revenue`), with FX conversion and
  **account-timezone → UTC date** normalization.
- `t3_channel_performance`: blended CPM/CPC/CPA/ROAS across owned programmatic + all walled gardens,
  using **owned attributed** conversions rather than each platform's self-reported ones.
- `t3_advertiser_pnl`: spend (all channels) vs. attributed revenue, margin, by advertiser × month.

### FR-11 — Discrepancy reconciliation
- `t3_discrepancy`: per `report_date` × `channel` × `campaign`, compares log-level truth
  (`t3_delivery_daily`) to platform-reported (`t2_platform_spend`) for impressions, clicks, spend,
  and conversions; emits absolute and % delta plus a severity band.
- Also reports **platform self-reported vs. our attribution** conversions — the classic
  "Meta says 400 conversions, we see 240" conversation.
- `custom_checks`: spend discrepancy within ±10% is `blocking: false` (warn), beyond ±25% is
  `blocking: true`. Thresholds are documented, configurable parameters.

### FR-12 — Serving views
- `serving_trader_live` — last 24h from 15-min rollup ∪ sealed hourly, with derived ratios.
- `serving_advertiser_report` — daily attributed performance + channel mix + reach/frequency.
- `serving_data_ops` — freshness, row counts, check results, discrepancy severity, IVT rate.

### FR-13 — DAC dashboards (three personas, one semantic layer)
- `semantic/` defines each metric in §7 **once** — `win_rate`, `ctr`, `cvr`, `ecpm`, `ecpa`, `roas`,
  `pacing_index`, `reach`, `avg_frequency`, `ivt_rate`, `discrepancy_pct` — plus the shared
  dimension set.
- **`trader_live.dashboard`** — win-rate and spend time series, pacing gauges per campaign, loss-reason
  bar, clearing-price P50/P95 lines, top exchanges table. Filters: time range, campaign, exchange.
- **`advertiser_report.dashboard`** — funnel chart (bid→win→imp→click→conv), ROAS by channel,
  attributed conversions by model (last-touch vs. position-based) side by side, reach/frequency
  histogram, creative performance table, sankey of channel → conversion path. Filters: date range,
  advertiser, channel multiselect, attribution-model dropdown.
- **`data_ops.dashboard`** — discrepancy heatmap by channel × day, freshness metrics, IVT trend,
  failed-check table.
- Verify DAC↔ClickHouse connection support first (O-3).

### FR-14 — Governance & documentation
- Every asset: `owner`, `description`, `tags` (`layer:t1|t2|t3|serving`, `domain:*`,
  `grain:*`, gating tags), `domains`, `meta` (grain, freshness SLA, additivity class,
  restatement window), and per-column descriptions + checks.
- Pipeline-level `meta` states reporting currency, reporting timezone, IVT policy, attribution
  windows, and restatement tiers — the four things every adtech stakeholder asks.
- `bruin docs` generates the static docs site; README carries the industry primer (§2) so the
  template teaches the domain, not just the tooling.

---

## 9. Proposed asset layout

```
bruin-adtech-clickhouse/                          # Pipeline 1 — delivery plane, */15 * * * *
├── pipeline.yml
├── README.md                                     # industry primer, run modes, Mode 1 vs 2
├── assets/
│   ├── t1_s3/                                    # FR-1 — object storage path
│   │   ├── t1_auctions_raw.asset.yml             # ingestr s3:// Parquet   [requires-s3]
│   │   ├── t1_impressions_raw.asset.yml          # ingestr s3://          [requires-s3]
│   │   ├── t1_clicks_raw.asset.yml               # ingestr s3://          [requires-s3]
│   │   ├── t1_conversions_raw.asset.yml          # ingestr s3://          [requires-s3]
│   │   └── t1_partition_sensor.asset.yml         # clickhouse.sensor.query
│   ├── t1_kafka/                                 # FR-1b — streaming path
│   │   ├── t1_auctions_kafka.asset.yml           # ingestr kafka:// → msg_id + JSON data
│   │   ├── t1_impressions_kafka.asset.yml        [requires-kafka]
│   │   ├── t1_clicks_kafka.asset.yml             [requires-kafka]
│   │   ├── t1_conversions_kafka.asset.yml        [requires-kafka]
│   │   └── t1_kafka_parsed.sql                   # JSONExtract → shared t1_*_raw contract
│   ├── t1_offline/
│   │   └── seed_generator.py                     # --sink table|kafka     [offline-demo]
│   ├── seeds/
│   │   ├── seed_advertisers.{asset.yml,csv}
│   │   ├── seed_campaign_flights.{asset.yml,csv}
│   │   ├── seed_budget_changes.{asset.yml,csv}   # effective-dated budgets + caps
│   │   ├── seed_creatives.{asset.yml,csv}
│   │   ├── seed_channel_map.{asset.yml,csv}
│   │   ├── seed_iab_categories.{asset.yml,csv}
│   │   └── seed_inventory_tiers.{asset.yml,csv}
│   ├── t2/
│   │   ├── t2_campaign_dim.sql                   # + hooks.post → CREATE DICTIONARY
│   │   ├── t2_budget_asof.sql                    # effective-dated budget/cap intervals
│   │   ├── t2_auctions.sql
│   │   ├── t2_impressions.sql
│   │   ├── t2_clicks.sql
│   │   ├── t2_conversions.sql
│   │   ├── t2_identity_map.sql
│   │   ├── t2_touchpoints.sql                    # unified stream; SAMPLE BY
│   │   └── t2_attributed_conversions.sql         # ASOF JOIN; unit-tested
│   ├── t3/
│   │   ├── t3_delivery_15m.sql
│   │   ├── t3_delivery_hourly.sql                # + quantileTDigest from t2
│   │   ├── t3_delivery_daily.sql
│   │   ├── t3_pacing.sql                         # ASOF JOIN t2_budget_asof; unit-tested
│   │   ├── t3_funnel.sql                         # windowFunnel
│   │   ├── t3_reach_frequency.sql                # uniqCombined + freq buckets
│   │   ├── t3_ivt_monitor.sql
│   │   ├── t3_inventory_quality.sql
│   │   └── t3_creative_performance.sql           # + hooks.post → ADD PROJECTION
│   ├── serving/
│   │   └── serving_trader_live.sql               # view
│   └── advanced/                                 # Mode 2, optional, tag: advanced-mode2
│       └── mv_delivery_agg.sql                   # hooks: AggregatingMergeTree + native MV
├── docker-compose.yml                            # Redpanda (Kafka API) for the streaming path
├── Makefile                                      # kafka-up / kafka-seed / run-offline / run-kafka
└── unit_tests/                                   # attribution + pacing + additivity cases

bruin-adtech-spend-clickhouse/                    # Pipeline 2 — spend plane, @daily
├── pipeline.yml
├── README.md
├── assets/
│   ├── t1/
│   │   ├── t1_google_ads_report.asset.yml        [requires-google-ads]
│   │   ├── t1_facebook_ads_report.asset.yml      [requires-meta-ads]
│   │   ├── t1_tiktok_ads_report.asset.yml        [requires-tiktok-ads]
│   │   ├── t1_linkedin_ads_report.asset.yml      [requires-linkedin-ads]
│   │   ├── t1_reddit_ads_report.asset.yml        [requires-reddit-ads]
│   │   ├── t1_mmp_events.asset.yml               # adjust | appsflyer  [requires-mmp]
│   │   ├── t1_ga4_traffic.asset.yml              [requires-ga4]
│   │   └── t1_fx_rates.asset.yml                 # frankfurter (no auth)
│   ├── t2/
│   │   └── t2_platform_spend.sql                 # UNION ALL + FX + tz normalization
│   ├── t3/
│   │   ├── t3_channel_performance.sql
│   │   ├── t3_attribution_daily.sql
│   │   ├── t3_discrepancy.sql                    # depends: [{ uri: ...t3_delivery_daily }]
│   │   └── t3_advertiser_pnl.sql
│   └── serving/
│       ├── serving_advertiser_report.sql
│       └── serving_data_ops.sql

dashboards/                                       # Bruin DAC (shared)
├── semantic/                                     # all §7 metrics defined once
├── trader_live.dashboard.yml
├── advertiser_report.dashboard.tsx
└── data_ops.dashboard.yml
```

---

## 10. Representative asset sketches

### 10.1 Attribution — `ASOF JOIN` + unit-tested (the centerpiece)

```sql
/* @bruin
name: bruin_adtech.t2_attributed_conversions
type: clickhouse.sql
description: "Attributes each conversion to touchpoints within the lookback window; emits last-touch and position-based credit. Restates history as late conversions arrive."
materialization:
  type: table
  strategy: merge
parameters:
  engine: replacing_merge_tree
interval_modifiers:                       # requires --apply-interval-modifiers
  start: -7d
  end: 0h
depends:
  - bruin_adtech.t2_conversions
  - bruin_adtech.t2_touchpoints
owner: measurement@example.com
tags: [ "layer:t2", "domain:measurement", "grain:conversion" ]
meta:
  additivity: non-additive
  click_lookback_days: "30"
  view_through_lookback_days: "7"
columns:
  - { name: conversion_id, type: String, primary_key: true, checks: [ { name: not_null }, { name: unique } ] }
  - { name: conversion_date, type: Date }
  - { name: touchpoint_date, type: Nullable(Date) }
  - { name: person_key, type: String }
  - { name: last_touch_campaign_id, type: Nullable(UInt32) }
  - { name: touch_path, type: Array(String), description: "Ordered channel path for MTA" }
  - { name: credit_last_touch, type: Decimal(9,6) }
  - { name: credit_position_based, type: Decimal(9,6) }
  - { name: order_value_usd, type: Decimal(18,2) }
custom_checks:
  - name: credit_sums_to_one_per_conversion
    query: |
      SELECT count() FROM (
        SELECT conversion_id, sum(credit_position_based) AS c
        FROM bruin_adtech.t2_attributed_conversions
        GROUP BY conversion_id HAVING abs(c - 1) > 0.000001
      )
    value: 0
    blocking: true
  - name: no_touchpoint_after_conversion
    query: "SELECT count() FROM bruin_adtech.t2_attributed_conversions WHERE touchpoint_date > conversion_date"
    value: 0
    blocking: true
@bruin */
SELECT
    c.conversion_id,
    toDate(c.event_time)                        AS conversion_date,
    toDate(t.event_time)                        AS touchpoint_date,
    c.person_key,
    t.campaign_id                               AS last_touch_campaign_id,
    /* path + weights are computed in the CTE below in the real asset */
    [t.channel]                                 AS touch_path,
    1.0                                         AS credit_last_touch,
    1.0                                         AS credit_position_based,
    c.order_value_usd
FROM bruin_adtech.t2_conversions AS c
ASOF LEFT JOIN bruin_adtech.t2_touchpoints AS t
  ON c.person_key = t.person_key AND c.event_time >= t.event_time
WHERE c.event_time BETWEEN parseDateTime64BestEffort('{{ start_timestamp }}')
                       AND parseDateTime64BestEffort('{{ end_timestamp }}')
  AND (t.event_time IS NULL
       OR t.event_time >= c.event_time - INTERVAL 30 DAY)
```

> The real asset wraps this in CTEs that collect the full ordered path per conversion
> (`groupArray` over eligible touchpoints) and apply 40/20/40 position-based weights.
> `interval_modifiers` is what makes late conversions correct; `merge` on `conversion_id` is what
> makes the restatement non-duplicating.

### 10.2 Delivery rollup — 15-minute grain, additive metrics only

```sql
/* @bruin
name: bruin_adtech.t3_delivery_15m
type: clickhouse.sql
description: "Additive delivery metrics at 15-minute grain. Non-additive metrics (reach, P95 clearing price) are deliberately absent."
materialization:
  type: table
  strategy: time_interval
  incremental_key: bucket_15m
  time_granularity: timestamp
parameters:
  engine: replacing_merge_tree
  engine.index_granularity: 8192
interval_modifiers: { start: -1h, end: 0h }
depends: [ bruin_adtech.t2_auctions, bruin_adtech.t2_impressions, bruin_adtech.t2_clicks ]
tags: [ "layer:t3", "domain:delivery", "grain:15min" ]
meta: { additivity: additive, freshness_sla_minutes: "20" }
custom_checks:
  - { name: no_future_buckets, query: "SELECT count() FROM bruin_adtech.t3_delivery_15m WHERE bucket_15m > now()", value: 0, blocking: true }
  - { name: billable_lte_gross, query: "SELECT count() FROM bruin_adtech.t3_delivery_15m WHERE impressions_billable > impressions_gross", value: 0, blocking: true }
  - { name: wins_lte_bids, query: "SELECT count() FROM bruin_adtech.t3_delivery_15m WHERE wins > bids", value: 0, blocking: true }
@bruin */
SELECT
    toStartOfInterval(a.event_time, INTERVAL 15 MINUTE)   AS bucket_15m,
    a.advertiser_id, a.campaign_id, a.line_item_id, a.creative_id,
    a.exchange, a.ad_format, a.device_type, a.country, a.supply_tier,
    count()                                               AS bid_requests,
    countIf(a.bid_status != 'no_bid')                     AS bids,
    countIf(a.bid_status = 'bid_won')                     AS wins,
    sumIf(a.win_price_cpm, a.bid_status = 'bid_won')/1000 AS media_spend_usd
FROM bruin_adtech.t2_auctions AS a
WHERE a.event_time BETWEEN parseDateTime64BestEffort('{{ start_timestamp }}')
                       AND parseDateTime64BestEffort('{{ end_timestamp }}')
GROUP BY ALL
```

### 10.3 Restatement-safe platform ingestion

```yaml
# t1_facebook_ads_report.asset.yml
name: bruin_adtech.t1_facebook_ads_report
type: ingestr
description: "Meta Ads insights at ad × day grain. Re-pulls a 7-day window because Meta restates spend and conversions as attribution windows close."
tags: [ "layer:t1", "domain:spend", "requires-meta-ads" ]
interval_modifiers: { start: -7d, end: 0h }     # run with --apply-interval-modifiers
parameters:
  source_connection: facebook-ads
  source_table: "ads_insights"
  destination: clickhouse
  incremental_strategy: merge
  incremental_key: date_start
  engine: replacing_merge_tree
columns:
  - { name: date_start, type: Date, primary_key: true }
  - { name: ad_id, type: String, primary_key: true }
  - { name: spend, type: Decimal(18,4) }
  - { name: account_currency, type: LowCardinality(String) }
custom_checks:
  - { name: no_negative_spend, query: "SELECT count() FROM bruin_adtech.t1_facebook_ads_report WHERE spend < 0", value: 0, blocking: true }
```

---

## 11. Correctness requirements (mapped to §2.3)

| # | Problem | Requirement | Proven by |
|---|---|---|---|
| 1 | Late conversions | 7-day lookback every 15 min + 30-day daily restatement pass; `merge` on `conversion_id` | Seed injects a 21-day-late conversion; check confirms it lands in the right `touchpoint_date` and rewrites the daily mart |
| 2 | Platform restatement | `interval_modifiers` + `merge`/RMT per platform, window documented per platform | Seed restates a prior day's spend on run 2; row count unchanged, value updated |
| 3 | Discrepancy | `t3_discrepancy` with ±10% warn / ±25% blocking | Check fires at the injected drift level |
| 4 | Multi-currency | All money kept in source currency + `spend_usd` via `t1_fx_rates` on `rate_date`; missing-rate check | `not_null` on `spend_usd`; check for FX gaps |
| 5 | Timezone | Account timezone from `seed_channel_map`; platform `report_date` converted to a documented reporting-timezone date | Check: platform daily totals reconcile to log-level within tolerance only after tz normalization |
| 6 | Duplication | RMT dedup key per feed + `unique` checks on t2 grain. On the Kafka path this is the *only* correctness mechanism against at-least-once redelivery | Seed re-delivers an S3 partition **and** replays Kafka offsets after a simulated consumer restart; row counts stable in both |
| 7 | Identity | `t2_identity_map` deterministic stitch, consent-gated | Check: no non-consented `user_key` appears in the map; reach with vs. without stitching reported |
| 8 | IVT | Gross vs. billable metrics both materialized; IVT never deleted | `billable_lte_gross` check; `t3_ivt_monitor` |
| 9 | Cardinality | Sorting key favors time+campaign; bloom-filter skip indexes on `user_key`/`site_domain`/`creative_id`; a projection for the advertiser access path | README documents `EXPLAIN`/`system.query_log` before-after timings |
| 10 | Non-additivity | Additivity class in every asset's `meta`; non-additive metrics only at their computed grain | `custom_check` asserting no non-additive column exists in `t3_delivery_daily`; README explains |
| **11** | **Mid-flight budget & cap changes** (§5.4.1) | `t2_budget_asof` effective-dated intervals; `t3_pacing` and `t3_reach_frequency` `ASOF JOIN` the value in force on each date; paused days excluded from elapsed flight | Unit tests: budget raise mid-flight leaves prior-day pacing unchanged; pause-then-resume does not read as under-delivery; cap relaxation does not clear prior violations |
| **12** | **At-least-once stream delivery** | Kafka path uses `append` + RMT dedup on the event ID; the two ingestion paths are mutually exclusive by tag | Offset replay produces no duplicate rows; cross-path duplicate check fails if both paths run |

---

## 12. Features showcased

### ClickHouse

| Feature | Where |
|---|---|
`ReplacingMergeTree` dedup (+ `FINAL`/`argMax` read patterns) | t1 event feeds, platform reports
`LowCardinality(String)` on ~12 dimensions | all t1/t2
Column **codecs** (`Delta`+`ZSTD` on timestamps, `T64` on prices, `ZSTD` on ID strings) | t1 event tables, via hooks
**TTL** — 90-day raw event retention, rollups retained long | t1, via hooks
**Bloom-filter skip indexes** on high-cardinality columns | t2_touchpoints, t2_auctions, via hooks
**Projections** — second access path by advertiser/campaign | t3_creative_performance, via hooks
**Dictionaries** + `dictGet` enrichment instead of joins | t2_campaign_dim → t2 event assets
`windowFunnel()` / `sequenceMatch()` / `retention()` | t3_funnel
`uniqCombined()` / `uniqExact()` comparison, HLL trade-off | t3_reach_frequency
`quantileTDigest()` percentiles | t3_delivery_hourly
**`ASOF JOIN`** for attribution | t2_attributed_conversions
`SAMPLE BY intHash64(person_key)` | t2_touchpoints
`groupArray` / `arrayJoin` / array weights for MTA paths | t2_attributed_conversions
`sumMap` / conditional aggregates (`countIf`/`sumIf`) | delivery rollups
Multi-grain rollup cascade + additivity discipline | t3 delivery chain
`AggregatingMergeTree` + native incremental MV | §13 Mode 2 appendix

### Bruin

| Feature | Where |
|---|---|
`ingestr` — object storage (S3/GCS Parquet) | t1 event feeds
**`ingestr` — Kafka source (streaming path)** | `t1_kafka/`, same targets as the S3 path
`ingestr` — 5 ad platforms + MMP + GA4 + FX API | Pipeline 2 t1
`seed` assets (CSV) | 7 dimension seeds incl. effective-dated budgets
Python assets | synthetic funnel generator, scale-switched, table-or-Kafka sink
Interchangeable ingestion paths onto one DAG (tag-selected) | S3 vs. Kafka vs. offline
Hand-rolled SCD2 where `scd2_by_time` is unsupported on ClickHouse | `t2_budget_asof`
`source` assets | documenting external log feeds
`sensor` assets (`clickhouse.sensor.query`) | partition-arrival gate
Materialization: `time_interval`, `merge`, `append`, `create+replace`, `ddl`, `view` | across layers
`interval_modifiers` (+ `--apply-interval-modifiers`) | late conversions, platform restatement
`parameters.engine` / `engine.<setting>` | RMT + index_granularity
`hooks.pre` / `hooks.post` raw SQL | dictionaries, TTL, codecs, skip indexes, projections, MVs
**Cross-pipeline `depends: [{ uri: ... }]`** (+ `mode: symbolic`) | discrepancy mart
**`bruin unit-test`** | attribution logic (7 cases) + pacing/budget as-of (4 cases)
Column checks + `custom_checks` with `blocking` tiers | every layer
`tags` gating (offline vs. per-platform live) | all live assets
`domains`, `owner`, `meta`, column descriptions | governance parity with shop pipeline
Two pipelines, two schedules, one warehouse | 15-min + daily
`bruin lineage`, `bruin docs`, `bruin data-diff`, `bruin query` | operating notes in README
**DAC** — 3 dashboards, shared semantic layer, filters, funnel/sankey/heatmap/gauge widgets | `dashboards/`

---

## 13. Bruin ClickHouse support boundary & escape hatches

**Supported today** (verified): strategies `create+replace`, `append`, `delete+insert`,
`time_interval`, `truncate+insert`, `merge`, `ddl`; logical `view`; engines `merge_tree`,
`replacing_merge_tree`, `shared_merge_tree`, `replicated_merge_tree`; `engine.<setting>`
pass-through; native ClickHouse column types (`DateTime64(3,'UTC')`, `Nullable(T)`,
`LowCardinality(String)`); `seed` assets (CSV/Parquet/JSON/JSONL/Avro); `source` assets;
`clickhouse.sensor.table` / `clickhouse.sensor.query`. **Not supported:** `scd2_by_column`,
`scd2_by_time`.

**Not modeled as first-class asset config** (and this template needs them):
`AggregateFunction` state columns with `AggregatingMergeTree`/`SummingMergeTree`, native
trigger-based `CREATE MATERIALIZED VIEW`, `PARTITION BY`, `TTL`, per-column `CODEC`, `ORDER BY`
beyond primary key, data-skipping indexes, projections, `SAMPLE BY`, and `CREATE DICTIONARY`.

**Resolution — three modes, all documented in the README:**

- **Mode 1 (default, fully Bruin-native):** Bruin-orchestrated incremental rollups
  (`time_interval` + `interval_modifiers`, `merge`). Delivers every metric in §7 correctly at the
  15-minute cadence. Non-additive metrics recomputed from t2.
- **Mode 1.5 (recommended, the interesting finding):** use **`hooks.pre` / `hooks.post`** raw SQL to
  apply the physical-layout features Bruin doesn't model — `ALTER TABLE … MODIFY TTL`,
  `ADD INDEX … TYPE bloom_filter`, `ADD PROJECTION`, `MODIFY COLUMN … CODEC(Delta, ZSTD)`,
  `CREATE DICTIONARY`. Bruin still owns the table and the DAG; hooks own the physics. This keeps
  the template idiomatic *and* lets it show off ClickHouse properly. Idempotence
  (`IF NOT EXISTS`) is a hard requirement for every hook.
- **Mode 2 (optional appendix, `tag: advanced-mode2`):** native `AggregatingMergeTree` with
  `uniqState`/`quantileState` + a trigger MV, created via hooks. This is what makes **unique reach
  and P95 clearing price additive** — precisely the two metrics Mode 1 must recompute. The clearest
  possible motivation for the product ask.

**Product feedback (O-1):** first-class `aggregating_merge_tree` / `summing_merge_tree` engines, a
`materialized_view` strategy, and declarative `partition_by` / `ttl` / `codec` / `indexes` /
`projections` / `sample_by` in `materialization` would let Bruin own Mode 2 natively. AdTech is the
strongest possible justification: it is the vertical where these features are the reason ClickHouse
was chosen.

**Streaming path (built — FR-1b):** ingestr's **Kafka** source is a real capability and the template
uses it, with a local Redpanda container so it runs offline. Three things belong in the README rather
than being glossed:

- **Fixed landing schema.** Kafka lands `msg_id` + a JSON `data` column, not typed fields. The Kafka
  path therefore carries one extra parse asset that the S3 path doesn't (FR-1b). Do not pretend the
  two paths are byte-identical in shape — they converge at `t1_*_raw`, not before.
- **Continuous mode exists but doesn't fit a scheduled DAG.** `stream: true` consumes indefinitely
  and never exits, so it cannot be a scheduled asset. The demo default is batch drain-per-run;
  continuous is shown standalone. Freshness in the scheduled pipeline is the 15-minute cadence — the
  same honest framing Template A uses for CDC.
- **ClickHouse's native `Kafka` table engine** is a third option: genuinely continuous, but Bruin
  doesn't model it and it moves ingestion ownership outside the DAG (no lineage, no checks, no
  retries). Named with the trade-off, not built.
- `kinesis` and `rabbitmq` ingestr sources are noted as drop-in alternatives.

**SCD2 gap:** `scd2_by_column` / `scd2_by_time` are unsupported on ClickHouse, so the effective-dated
budget timeline (`t2_budget_asof`, FR-4) is hand-rolled from an append-only source. Second
product-feedback item after O-1.

---

## 14. Demo narratives

### 14.1 Five-minute executive demo
1. `bruin run` the offline path — one command, no credentials, populates the whole warehouse.
2. Open **advertiser_report** DAC dashboard: funnel, ROAS by channel, reach & frequency.
3. Toggle the **attribution-model** dropdown — last-touch vs. position-based changes ROAS
   materially. "Your attribution model is a business decision, and here it is in version control."
4. Open **data_ops**: the discrepancy heatmap. "Here is the 6% gap between Meta's invoice and your
   log-level truth, quantified daily, with an alert threshold."
5. `git diff` on a metric definition in `semantic/`. "Every number on these dashboards is
   code-reviewed."

### 14.2 Twenty-minute technical demo
1. `bruin lineage` on `t3_discrepancy` — one DAG spanning two pipelines and eight sources.
2. Show `t1_facebook_ads_report.asset.yml` — `interval_modifiers: start: -7d` + `merge`. Run twice;
   restated spend updates, row count doesn't. "This is the bug in most marketing warehouses."
3. `bruin unit-test` the attribution asset — the 21-day-late conversion case passes.
4. `bruin query` the `ASOF JOIN` plan; show `EXPLAIN` with and without the bloom-filter skip index.
5. Show `t3_delivery_daily` has no `unique_reach` column, then show `t3_reach_frequency` computing it
   per grain. Explain additivity. Then show Mode 2's `uniqState` making it additive.
6. Show `windowFunnel` on `t2_touchpoints` and the funnel widget it feeds.
7. **Swap ingestion under the DAG:** `make kafka-up && make run-kafka`. Same tables, same marts, same
   dashboards — only the four t1 assets changed. Then replay offsets and show row counts hold because
   of the RMT dedup key.
8. **Mid-flight budget change:** open the pacing chart with its change-point annotations, then show
   `t2_budget_asof` and the `ASOF JOIN`. Point out that the naive static-budget version would report
   this campaign as 60% under-pacing when it is actually on plan.
9. Break something: point a check threshold at real drift, watch the blocking check fail the run and
   the data-ops dashboard light up.

---

## 15. Milestones

| # | Milestone | Contents | Gate |
|---|---|---|---|
| **M0** | Feasibility spikes | Verify DAC↔ClickHouse (O-3), `hooks` raw-SQL on ClickHouse (O-2), cross-pipeline `uri` locally (O-8), `ASOF JOIN` at demo scale (O-11), **ingestr Kafka→ClickHouse offset/cursor semantics (O-16)** | All five answered in writing before M1 |
| **M1** | Offline skeleton | Seed generator (`small`, `--sink table`) → t1 → t2 event layer → `t3_delivery_15m` → `serving_trader_live` | `bruin run --tag offline-demo` green |
| **M2** | Attribution | `t2_touchpoints`, `t2_identity_map`, `t2_attributed_conversions`, 7 unit tests, late-conversion restatement | `bruin unit-test` green; late-conversion case proven |
| **M3** | Marts & physics | Rollup cascade, **`t2_budget_asof` + budget-aware pacing (4 unit tests)**, funnel, reach/frequency, IVT, inventory, creative + Mode 1.5 hooks (TTL, codecs, indexes, projection, dictionary) | Before/after query timings documented; budget-change cases pass |
| **M4** | Spend plane | Pipeline 2: FX + platform reports (seed-backed first, then live), `t2_platform_spend`, channel performance, `t3_discrepancy` | Discrepancy check fires at injected drift |
| **M5** | **Streaming path** | `docker-compose` Redpanda, generator `--sink kafka`, four `t1_kafka/` ingestr assets, mutual-exclusion check, consumer-lag metric, Makefile targets | `make run-kafka` produces marts identical to the offline path; offset replay adds no rows |
| **M6** | DAC | Semantic layer + 3 dashboards + filters + pacing change-point annotations | All three render against ClickHouse |
| **M7** | Live sources | Real S3 feed + at least two real ad-platform credentials, tag-gated, documented setup | Live path runs; offline path unaffected |
| **M8** | Polish | READMEs (incl. industry primer), `bruin docs`, scale test at `medium`/`large`, Mode 2 appendix, product-feedback writeup (O-1 + SCD2) | Acceptance criteria §16 all met |

---

## 16. Acceptance criteria

1. `bruin validate` passes on both pipelines.
2. `bruin run --tag offline-demo --apply-interval-modifiers` completes with **no credentials of any
   kind** and populates all three serving views.
3. Running the offline path **twice** produces byte-identical marts (idempotence), verified by
   reconciliation `custom_checks`.
4. A seeded conversion arriving 21 days late is attributed to the correct touchpoint and rewrites
   the affected daily mart on the next run.
5. A restated platform report updates spend without changing row counts.
6. `t3_discrepancy` reports the injected drift within 0.5 percentage points of the seeded value, and
   the ±25% blocking check fails when the seed is configured to breach it.
7. `bruin unit-test` passes all attribution cases, including out-of-window, no-touchpoint, and
   non-consented.
8. No non-additive metric appears in any asset coarser than its computed grain (enforced by check).
9. **Budget changes:** a mid-flight budget raise leaves prior-day pacing indices byte-identical; a
   pause-then-resume line item is not flagged as under-delivering for its paused days; a cap
   relaxation does not clear violations recorded before it took effect. All three are unit tests.
10. **Streaming path:** `make kafka-up && make run-kafka` produces marts **identical** to the
    offline path at the same seed and scale (the JSON parse step is lossless); replaying consumer
    offsets adds zero rows; running the S3 and Kafka paths together fails the mutual-exclusion check
    rather than silently double-counting.
11. All three DAC dashboards render against ClickHouse and share one `semantic/` definition per metric.
12. `medium` scale (~10M auction rows) completes on ClickHouse Cloud within a documented runtime, and
    the README records query timings before/after the Mode 1.5 hooks.
13. README explains the funnel, the twelve hard problems, the three ingestion paths, the three modes,
    and additivity — a reader with no adtech background can follow it.
14. `bruin docs` site builds with every asset documented and owned.

---

## 17. Risks & open questions

| ID | Item | Impact | Resolution path |
|---|---|---|---|
| **O-1** | `AggregatingMergeTree` / native MV not first-class in Bruin | Non-additive metrics recomputed rather than aggregated | Mode 1 default, Mode 2 via hooks appendix; file product feedback |
| **O-2** | `PARTITION BY`, `TTL`, `CODEC`, skip indexes, projections, `SAMPLE BY`, `CREATE DICTIONARY` not modeled | Half the ClickHouse showcase | **M0 spike:** confirm `hooks.pre`/`hooks.post` execute arbitrary SQL on the ClickHouse connection and survive re-runs idempotently. If not, drop to documented-only and reduce scope of §12 |
| **O-3** | DAC ↔ ClickHouse connection support unconfirmed (docs list Postgres/MySQL/Snowflake/BQ/Redshift/Databricks "+ more via Bruin") | FR-13 blocked | **M0 spike.** Fallback: `bruin docs` + a static `dac build` against a materialized extract |
| **O-4** | ClickHouse Cloud IP allowlist blocks this machine | Cannot verify SQL live | Validate all SQL with `clickhouse local` first (known constraint) |
| **O-5** | No real ad-platform credentials for most demo runs | Live path unusable by default | Offline seed path is the default and is mandatory; every live asset tag-gated; M6 wires only 2+ platforms |
| **O-6** | Demo data volume vs. Cloud cost/quota | `large` scale may be unaffordable | `ADTECH_SCALE` switch; `small` is the committed default; document row counts and cost |
| **O-7** | `interval_modifiers` needs `--apply-interval-modifiers`; a 30-day lookback on every 15-min run is expensive | Cost / correctness trade-off | Two-tier restatement (7d per-run, 30d daily); document the trade-off explicitly as a teaching point |
| **O-8** | Cross-pipeline `uri` deps may be Bruin-Cloud-only for scheduling | Local demo ordering | **M0 spike.** Fallback: `mode: symbolic` for lineage + `clickhouse.sensor.table` gate, and a documented run order |
| **O-9** | `ASOF JOIN` memory at scale | M2/M3 failure at `medium`+ | Pre-filter touchpoints to the lookback window, partition by `person_key` hash range, or fall back to `argMax` over a windowed join; benchmark in M0 |
| **O-10** | `windowFunnel` needs one unified event table | Design constraint | `t2_touchpoints` is that table by construction (FR-5) |
| **O-11** | Attribution restatement rewrites historical marts | Marts must be restatement-safe | All daily marts use `merge`/`delete+insert` keyed on date; both `conversion_date` and `touchpoint_date` exposed |
| **O-12** | Scope is large (two pipelines, ~40 assets) | Delivery risk | M1–M3 (delivery plane, offline) is a self-contained, demo-able deliverable; M4+ is additive. Ship in that order |
| **O-13** | Synthetic identity/PII | Compliance optics | Only synthetic hashed keys; consent flags modeled; README states no real PII, ever |
| **O-14** | Which ad platforms to actually wire | Maintenance burden | Build all five as seed-backed assets; wire live credentials for Google Ads + Meta Ads only |
| **O-15** | Overlap with `bruin-shop-clickhouse` marts | Repo redundancy | Zero shared sources; the only conceptual overlap is "daily KPI mart", and here it is attribution- and discrepancy-driven |
| **O-16** | ingestr Kafka semantics — **mostly resolved 2026-08-18** | FR-1b / M5 | Confirmed from docs: `bootstrap_servers` + `group_id` for offsets, `batch_size` 3000 / `batch_timeout` 3s, lands **`msg_id` + JSON `data`** (not flattened → parse step added), `stream: true` is continuous and therefore unschedulable. **Still open:** ClickHouse is documented as an ingestr destination generally, but the Kafka examples use DuckDB — confirm the Kafka→ClickHouse pair specifically in M0 |
| **O-17** | Campaign config modeled as a static effective-dated seed, not CDC | Realism | Deliberate. Ad events are immutable logs — CDC is a category error for them — and the config plane's mutation stream is already Template A's story. README states that in production `seed_budget_changes` arrives via `postgres+cdc://` from `campaigns`/`line_items`, and that the analytical consequence is identical |
| **O-18** | Redpanda adds a Docker dependency to the repo | Onboarding friction | Kafka path is strictly opt-in behind `requires-kafka`; the default demo needs no Docker. Aligns with the local Docker verification setup already used in this repo |
| **O-19** | Two ingestion paths writing the same tables | Silent double-count if both run | Mutual-exclusion `custom_check` on duplicate event IDs across paths + a pipeline-level note; Makefile targets never select two paths |

---

## 18. References

**ClickHouse × AdTech**
- [AWS Advertising & Marketing Technology Competency](https://clickhouse.com/blog/achieves-aws-advertising-marketing-technology-competency)
- [ClickHouse for adtech platforms](https://www.tinybird.co/blog/clickhouse-adtech-platforms) (InMobi P99, engines, MVs)
- [Real-time bid tracking with ClickHouse](https://chistadata.com/real-time-bid-tracking-and-optimization-with-clickhouse-in-high-performance-data-pipelines/)
- [ClickHouse at LifeStreet](https://altinity.com/blog/clickhouse-at-lifestreet-performance-marketing-is-as-strong-as-your-data-platform)
- [ClickHouse use cases in 2025: AdTech to Finance](https://www.gocodeo.com/post/clickhouse-use-cases-in-2025-from-ad-tech-to-finance-analytics)
- [ClickHouse use cases](https://clickhouse.com/use-cases) · [Industries](https://clickhouse.com/industries)

**ClickHouse features**
- [Incremental materialized views](https://clickhouse.com/docs/materialized-view/incremental-materialized-view) · [Cascading MVs](https://clickhouse.com/docs/guides/developer/cascading-materialized-views)
- [Working with JOINs](https://clickhouse.com/docs/guides/working-with-joins) · [Join types](https://clickhouse.com/blog/clickhouse-fully-supports-joins-part1)
- [ASOF JOIN for time-series](https://oneuptime.com/blog/post/2026-03-31-clickhouse-asof-join/view)
- [Tracking ad impressions and clicks](https://oneuptime.com/blog/post/2026-03-31-clickhouse-track-ad-impressions-and-clicks/view) · [Ad revenue attribution](https://oneuptime.com/blog/post/2026-03-31-clickhouse-ad-revenue-attribution/view)
- [Product analytics with ClickHouse](https://clickhouse.com/blog/building-product-analytics-with-clickhouse) (funnel/retention functions)

**AdTech industry**
- [DSP vs SSP: 2026 guide](https://improvado.io/blog/dsp-vs-ssp-programmatic-guide) · [Ad-tech stack explained](https://perform.digital/blogs/ad-tech-stack-explained/)
- [AdTech trends 2026](https://epom.com/blog/digital-advertising/ad-tech-trends) · [AdTech 2026: retail media, CTV, cookie reversal](https://everything-pr.com/adtech-2026-ai-search-ads-retail-media-ctv-and-the-cookie-reversal/)
- [CTV advertising trends 2026](https://www.aidigital.com/blog/ctv-advertising-trends) · [Data clean rooms](https://www.aidigital.com/blog/what-is-a-data-clean-room)
- [AdTech software development guide 2026](https://www.tuvoc.com/blog/adtech-software-development-guide/) · [AdTech predictions 2026](https://spyro-soft-adtech.com/adtech-predictions-2026/)

**Bruin**
- [ClickHouse platform support](https://getbruin.com/docs/bruin/platforms/clickhouse.html) · [Materialization](https://getbruin.com/docs/bruin/assets/materialization.html) · [Asset definition schema](https://getbruin.com/docs/bruin/assets/definition-schema.html)
- [Incremental vs full refresh](https://getbruin.com/learn/incremental-vs-full-refresh-runs/) (`interval_modifiers`)
- ingestr: [docs](https://getbruin.com/docs/ingestr/) · [repo + source matrix](https://github.com/bruin-data/ingestr) · **Kafka source: [ingestr](https://getbruin.com/docs/ingestr/supported-sources/kafka.html) · [Bruin asset](https://getbruin.com/docs/bruin/ingestion/kafka.html)** · [Google Ads](https://getbruin.com/docs/bruin/ingestion/google-ads.html) · [Facebook Ads](https://getbruin.com/docs/ingestr/supported-sources/facebook-ads.html) · [TikTok Ads](https://getbruin.com/docs/bruin/ingestion/tiktokads.html) · [LinkedIn Ads](https://getbruin.com/docs/bruin/ingestion/linkedinads.html) · [Adjust](https://getbruin.com/docs/ingestr/supported-sources/adjust.html) · [Applovin](https://getbruin.com/docs/bruin/ingestion/applovin.html) · [Google Analytics](https://getbruin.com/docs/ingestr/supported-sources/google_analytics.html)
- DAC: [Overview](https://getbruin.com/docs/dac/) · [Academy](https://getbruin.com/learn/bruin-dac/) · [repo](https://github.com/bruin-data/dac)
- [Marketing analyst academy](https://getbruin.com/learn/marketing-analyst/ingest-data/) (Google Ads + Klaviyo + GA4)

**Repo**
- `bruin-clickhouse-101` · `bruin-shop-clickhouse` · [`payments-clickhouse-requirements.md`](./payments-clickhouse-requirements.md) · [`ideas.md`](./ideas.md)
