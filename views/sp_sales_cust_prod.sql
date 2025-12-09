CREATE OR REPLACE VIEW vw_sales_customer_product AS
SELECT 
    sl.sale_id,
    sl.sale_date,
    sl.quantity,
    sl.total_value,

    cl.customer_id,
    cl.first_name,
    cl.last_name,
    cl.region,

    p.product_id,
    p.product_name,
    p.category
FROM sales_strat_plan.sales sl
LEFT JOIN cust_mstr.customers cl 
       ON sl.customer_id = cl.customer_id
LEFT JOIN matrl_mstr.products p
       ON sl.product_id = p.product_id;
