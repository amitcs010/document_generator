CREATE OR REPLACE PROCEDURE sp_load_sales()
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE NOTICE 'Refreshing sales tabels master tables...';

    insert into sales_strat_plan.sales  values (SELECT
    sale_id,
    customer_id,
    product_id,
    quantity,
    price,
    (quantity * price) AS total_value,
    sale_date::date AS sale_date
FROM stage.sales
WHERE quantity > 0
  AND price > 0
)

END;
$$;
