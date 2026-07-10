/* @bruin
name: country_revenue
type: clickhouse.sql
materialization:
   type: table

depends:
    - customer_order_summary

columns:
  - name: country
    type: varchar
    description: "Customer country."
    primary_key: true
    checks:
        - name: not_null
        - name: unique
  - name: customer_count
    type: integer
    description: "Number of customers in the country."
    checks:
        - name: positive
  - name: paid_order_count
    type: integer
    description: "Paid orders from the country."
    checks:
        - name: non_negative
  - name: total_paid_amount
    type: float
    description: "Total paid revenue in USD."
    checks:
        - name: non_negative
  - name: average_paid_amount_per_customer
    type: float
    description: "Average paid revenue per customer in USD."
    checks:
        - name: non_negative
@bruin */

SELECT
    country,
    customer_count,
    paid_order_count,
    total_paid_amount,
    round(total_paid_amount / customer_count, 2) AS average_paid_amount_per_customer
FROM (
    SELECT
        country,
        count() AS customer_count,
        sum(paid_order_count) AS paid_order_count,
        sum(total_paid_amount) AS total_paid_amount
    FROM customer_order_summary
    GROUP BY country
)
ORDER BY total_paid_amount DESC
