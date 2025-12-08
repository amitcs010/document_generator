CREATE OR REPLACE PROCEDURE sp_load_products()
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE NOTICE 'Refreshing cust master tables...';

    insert into matrl_mstr.products values (SELECT
    product_id,
    product_name,
    category,
    price,
    updated_at
FROM stage.products)

END;
$$;
