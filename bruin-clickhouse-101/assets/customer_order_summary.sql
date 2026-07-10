/* @bruin
name: customer_order_summary
type: clickhouse.sql
materialization:
   type: table
depends:
    - raw_customers
    - raw_orders

columns:
  - name: customer_id
    type: integer
    description: "Customer identifier."
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
  - name: lifecycle_stage
    type: varchar
    description: "Simple customer lifecycle segment."
  - name: order_count
    type: integer
    description: "All orders for the customer, including refunds."
    checks:
        - name: non_negative
  - name: paid_order_count
    type: integer
    description: "Paid orders for the customer."
    checks:
        - name: non_negative
  - name: total_paid_amount
    type: float
    description: "Total paid revenue in USD."
    checks:
        - name: non_negative
  - name: first_order_date
    type: date
    description: "First order date for the customer."
  - name: latest_order_date
    type: date
    description: "Latest order date for the customer."
@bruin */

SELECT
    c.customer_id AS customer_id,
    c.customer_name AS customer_name,
    c.country AS country,
    c.lifecycle_stage AS lifecycle_stage,
    count(o.order_id) AS order_count,
    countIf(o.order_status = 'paid') AS paid_order_count,
    sumIf(o.amount, o.order_status = 'paid') AS total_paid_amount,
    min(o.order_date) AS first_order_date,
    max(o.order_date) AS latest_order_date
FROM raw_customers AS c
LEFT JOIN raw_orders AS o
    ON c.customer_id = o.customer_id
GROUP BY
    c.customer_id,
    c.customer_name,
    c.country,
    c.lifecycle_stage
