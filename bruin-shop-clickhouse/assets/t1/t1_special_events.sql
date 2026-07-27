/* @bruin
name: bruin_shop.t1_special_events
type: clickhouse.sql
description: "T1 catalog of planned campaigns and operational events that affect ecommerce performance."
materialization:
   type: table

custom_checks:
  - name: contains rows
    description: Ensures the materialized table is not empty.
    query: SELECT count() > 0 FROM bruin_shop.t1_special_events
    value: 1
    blocking: true
  - name: event dates are ordered
    description: Ensures every special event ends on or after its start date.
    query: |
      SELECT event_id
      FROM bruin_shop.t1_special_events
      WHERE end_date < start_date
    count: 0
    blocking: true
columns:
  - name: event_id
    type: varchar
    description: "Identifier of the associated special event."
    primary_key: true
    checks:
        - name: not_null
        - name: unique
  - name: event_name
    type: varchar
    description: "Human-readable name of the special event."
  - name: event_type
    type: varchar
    description: "Classification of the special event scenario."
    checks:
      - name: accepted_values
        value: ["campaign_failure", "campaign_win", "outage", "product_defect", "stockout"]
  - name: start_date
    type: date
    description: "Date on which the event starts."
  - name: end_date
    type: date
    description: "Date on which the event ends."
  - name: channel
    type: varchar
    description: "Marketing or acquisition channel associated with the record."
  - name: product_id
    type: varchar
    description: "Stable identifier of the product."
  - name: spend_multiplier
    type: float
    description: "Event-specific multiplier applied to marketing spend."
    checks:
      - name: non_negative
  - name: session_multiplier
    type: float
    description: "Event-specific multiplier applied to session volume."
    checks:
      - name: non_negative
  - name: conversion_multiplier
    type: float
    description: "Event-specific multiplier applied to conversion behavior."
    checks:
      - name: non_negative
@bruin */

WITH arrayJoin([
    ('paid_search_broad_match_failure', 'Google search broad-match failure', 'campaign_failure', toDate('2026-01-12'), toDate('2026-01-18'), 'paid_search', 'all', 1.08, 1.00, 0.42),
    ('checkout_outage', 'Checkout outage and recovery', 'outage', toDate('2026-02-04'), toDate('2026-02-04'), 'all', 'all', 1.00, 0.30, 0.18),
    ('product_defect_black_tote', 'Black Tote Bag defect refund incident', 'product_defect', toDate('2026-02-20'), toDate('2026-02-24'), 'all', 'prod_accessories_09', 1.00, 1.00, 1.00),
    ('trail_shoe_launch', 'Instagram trail shoe launch', 'campaign_win', toDate('2026-03-10'), toDate('2026-03-17'), 'paid_social', 'prod_shoes_04', 1.35, 1.22, 1.70),
    ('trail_shoe_stockout', 'Instagram trail shoe stockout', 'stockout', toDate('2026-03-18'), toDate('2026-03-21'), 'paid_social', 'prod_shoes_04', 1.18, 0.95, 0.20),
    ('spring_outfit_campaign', 'Instagram spring outfit campaign', 'campaign_win', toDate('2026-04-08'), toDate('2026-04-14'), 'paid_social', 'all', 1.25, 1.15, 1.38),
    ('memorial_day_search', 'Google Memorial Day search campaign', 'campaign_win', toDate('2026-05-11'), toDate('2026-05-17'), 'paid_search', 'all', 1.30, 1.18, 1.42),
    ('google_summer_sale', 'Google Search - Summer Sale', 'campaign_win', toDate('2026-06-07'), toDate('2026-06-08'), 'paid_search', 'all', 1.45, 1.25, 1.55)
]) AS event
SELECT
    tupleElement(event, 1) AS event_id,
    tupleElement(event, 2) AS event_name,
    tupleElement(event, 3) AS event_type,
    tupleElement(event, 4) AS start_date,
    tupleElement(event, 5) AS end_date,
    tupleElement(event, 6) AS channel,
    tupleElement(event, 7) AS product_id,
    toFloat64(tupleElement(event, 8)) AS spend_multiplier,
    toFloat64(tupleElement(event, 9)) AS session_multiplier,
    toFloat64(tupleElement(event, 10)) AS conversion_multiplier
