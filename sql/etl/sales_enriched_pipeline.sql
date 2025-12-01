WITH o AS (
    SELECT * FROM raw.orders
),
c AS (
    SELECT * FROM raw.customers
),
p AS (
    SELECT * FROM raw.products
),
r AS (
    SELECT 
        o.order_id,
        o.customer_id,
        o.product_id,
        o.order_date,
        o.quantity,
        o.price,
        c.region,
        p.category,
        p.product_name,
        o.quantity * o.price AS order_amount
    FROM o
    LEFT JOIN c ON o.customer_id = c.customer_id
    LEFT JOIN p ON o.product_id = p.product_id
)

SELECT * FROM r;
