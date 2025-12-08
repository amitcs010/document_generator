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
FROM mdl_sales s
LEFT JOIN mdl_customers c 
       ON s.customer_id = c.customer_id
LEFT JOIN mdl_products p
       ON s.product_id = p.product_id;
