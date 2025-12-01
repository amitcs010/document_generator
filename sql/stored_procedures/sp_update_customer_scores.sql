CREATE OR REPLACE PROCEDURE sp_update_customer_scores()
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
    MERGE INTO analytics.customer_scores tgt
    USING (
        SELECT 
            customer_id,
            SUM(order_amount) AS lifetime_value,
            COUNT(*) AS order_count
        FROM analytics.sales_orders
        GROUP BY customer_id
    ) src
    ON tgt.customer_id = src.customer_id
    WHEN MATCHED THEN UPDATE 
        SET lifetime_value = src.lifetime_value,
            order_count = src.order_count
    WHEN NOT MATCHED THEN INSERT 
        (customer_id, lifetime_value, order_count)
        VALUES (src.customer_id, src.lifetime_value, src.order_count);

    RETURN 'Customer scores updated';
END;
$$;
