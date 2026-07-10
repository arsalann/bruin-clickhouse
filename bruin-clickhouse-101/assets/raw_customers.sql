/* @bruin
name: raw_customers
type: clickhouse.sql
materialization:
   type: table

columns:
  - name: customer_id
    type: integer
    description: "Unique customer identifier."
    primary_key: true
    checks:
        - name: not_null
        - name: positive
        - name: non_negative
        - name: unique
  - name: customer_name
    type: varchar
    description: "Customer display name."
    checks:
        - name: not_null
  - name: country
    type: varchar
    description: "Customer country."
    checks:
        - name: not_null
  - name: signup_date
    type: date
    description: "Date the customer signed up."
  - name: lifecycle_stage
    type: varchar
    description: "Simple customer lifecycle segment."
@bruin */

SELECT
    1 AS customer_id,
    'Ada Lovelace' AS customer_name,
    'United Kingdom' AS country,
    toDate('2024-01-15') AS signup_date,
    'enterprise' AS lifecycle_stage
UNION ALL
SELECT
    2 AS customer_id,
    'Grace Hopper' AS customer_name,
    'United States' AS country,
    toDate('2024-02-03') AS signup_date,
    'enterprise' AS lifecycle_stage
UNION ALL
SELECT
    3 AS customer_id,
    'Katherine Johnson' AS customer_name,
    'United States' AS country,
    toDate('2024-02-20') AS signup_date,
    'growth' AS lifecycle_stage
UNION ALL
SELECT
    4 AS customer_id,
    'Hedy Lamarr' AS customer_name,
    'Austria' AS country,
    toDate('2024-03-11') AS signup_date,
    'growth' AS lifecycle_stage
UNION ALL
SELECT
    5 AS customer_id,
    'Mary Jackson' AS customer_name,
    'United States' AS country,
    toDate('2024-04-09') AS signup_date,
    'self_serve' AS lifecycle_stage
