{{ config(materialized='table') }}

SELECT 
    product_id,
    product_name,
    category,
    sub_category,
    list_price
FROM {{ source('raw', 'products') }};
