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

    pd.product_id,
    pd.product_name,
    pd.category
FROM sales_strat_plan.sales sl
LEFT JOIN cust_mstr.customers cl 
       ON sl.customer_id = cl.customer_id
LEFT JOIN matrl_mstr.products pd
       ON sl.product_id = pd.product_id;
