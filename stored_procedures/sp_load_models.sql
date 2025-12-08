CREATE OR REPLACE PROCEDURE sp_load_models()
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE NOTICE 'Refreshing cust master tables...';

    insert into cust_mstr.customers values (SELECT
    customer_id,
    first_name,
    last_name,
    email,
    region,
    created_at
FROM stage.customers)

END;
$$;
