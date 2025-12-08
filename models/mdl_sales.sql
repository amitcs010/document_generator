DROP TABLE IF EXISTS mdl_sales;

CREATE TABLE mdl_sales AS
SELECT
    sale_id,
    customer_id,
    product_id,
    quantity,
    price,
    (quantity * price) AS total_value,
    sale_date::date AS sale_date
FROM src_sales
WHERE quantity > 0
  AND price > 0;
