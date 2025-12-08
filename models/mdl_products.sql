DROP TABLE IF EXISTS mdl_products;

CREATE TABLE mdl_products AS
SELECT
    product_id,
    product_name,
    category,
    price,
    updated_at
FROM src_products;
