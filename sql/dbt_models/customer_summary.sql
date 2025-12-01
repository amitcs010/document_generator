{{ config(materialized='table') }}

WITH orders AS (
    SELECT 
        customer_id,
        SUM(quantity * price) AS total_revenue,
        COUNT(*) AS total_orders
    FROM {{ ref('sales_orders') }}
    GROUP BY customer_id
),

customers AS (
    SELECT 
        customer_id,
        first_name,
        last_name,
        region
    FROM {{ source('raw', 'customers') }}
)

SELECT 
    c.customer_id,
    c.first_name,
    c.last_name,
    c.region,
    o.total_revenue,
    o.total_orders
FROM customers c
LEFT JOIN orders o
    ON c.customer_id = o.customer_id;
