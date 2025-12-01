CREATE OR REPLACE VIEW analytics.vw_top_customers AS
SELECT 
    customer_id,
    SUM(order_amount) AS total_spend
FROM analytics.sales_orders
GROUP BY customer_id
HAVING SUM(order_amount) > 10000;
