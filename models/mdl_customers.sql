DROP TABLE IF EXISTS mdl_customers;

CREATE TABLE mdl_customers AS
SELECT
    customer_id,
    first_name,
    last_name,
    email,
    region,
    created_at
FROM src_customers;
