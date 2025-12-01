CREATE OR REPLACE TABLE staging.sales_clean AS
SELECT 
    order_id,
    customer_id,
    product_id,
    TRY_CAST(order_date AS DATE) AS order_date,
    quantity,
    TRY_CAST(price AS NUMBER(10,2)) AS price
FROM raw.sales
WHERE order_id IS NOT NULL
  AND quantity > 0;
