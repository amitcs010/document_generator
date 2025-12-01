CREATE OR REPLACE PROCEDURE sp_refresh_daily_sales()
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
    TRUNCATE TABLE analytics.daily_sales;

    INSERT INTO analytics.daily_sales
    SELECT 
        order_id,
        customer_id,
        order_date,
        quantity,
        price,
        quantity * price AS order_amount
    FROM staging.sales_orders;

    RETURN 'Daily sales refreshed';
END;
$$;
