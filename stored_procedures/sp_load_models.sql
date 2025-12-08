CREATE OR REPLACE PROCEDURE sp_load_models()
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE NOTICE 'Refreshing model tables...';

    -- Load Sales Model
    EXECUTE '
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
        WHERE quantity > 0 AND price > 0;
    ';

    -- Load Customer Model
    EXECUTE '
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
    ';

    -- Load Product Model
    EXECUTE '
        DROP TABLE IF EXISTS mdl_products;
        CREATE TABLE mdl_products AS
        SELECT
            product_id,
            product_name,
            category,
            price,
            updated_at
        FROM src_products;
    ';

    RAISE NOTICE 'All model tables refreshed successfully.';
END;
$$;
