CREATE OR REPLACE VIEW vw_sales_customer_product AS
SELECT 
    s.sale_id,
    s.sale_date,
    s.quantity,
    s.total_value,

    c.customer_id,
    c.first_name,
    c.last_name,
    c.region,

    p.product_id,
    p.product_name,
    p.category
FROM sales_strat_plan.sales s
LEFT JOIN cust_mstr.customers c 
       ON s.customer_id = c.customer_id
LEFT JOIN matrl_mstr.products p
       ON s.product_id = p.product_id;
