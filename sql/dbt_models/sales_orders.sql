{{ config(materialized='incremental', unique_key='order_id') }}

WITH raw_orders AS (
    SELECT 
        order_id,
        customer_id,
        product_id,
        order_date,
        quantity,
        price
    FROM {{ source('raw', 'orders') }}
),

product_lookup AS (
    SELECT 
        product_id,
        category,
        sub_category
    FROM {{ ref('dim_products') }}
)

SELECT 
    r.order_id,
    r.customer_id,
    r.order_date,
    r.quantity,
    r.price,
    p.category,
    p.sub_category,
    r.quantity * r.price AS order_amount
FROM raw_orders r
LEFT JOIN product_lookup p
    ON r.product_id = p.product_id;
