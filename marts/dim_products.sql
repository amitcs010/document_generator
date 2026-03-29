-- ============================================================
-- marts.dim_products
-- Product dimension enriched with sales performance metrics.
-- ============================================================

DROP TABLE IF EXISTS marts.dim_products;

CREATE TABLE marts.dim_products
DISTSTYLE ALL
SORTKEY(product_id)
AS
WITH product_sales AS (
    SELECT
        product_id,
        SUM(quantity)                               AS total_units_sold,
        SUM(gross_revenue)                          AS total_revenue,
        SUM(gross_margin)                           AS total_margin,
        COUNT(DISTINCT order_id)                    AS order_count,
        COUNT(DISTINCT customer_id)                 AS customer_count,
        MIN(order_date)                             AS first_sold_date,
        MAX(order_date)                             AS last_sold_date,
        AVG(sold_unit_price)                        AS avg_selling_price,
        AVG(discount_pct)                           AS avg_discount_given
    FROM transforms.int_order_items
    WHERE order_status NOT IN ('cancelled', 'fraud_review')
    GROUP BY product_id
)

SELECT
    p.product_id,
    p.sku,
    p.product_name,
    p.category,
    p.subcategory,
    p.brand,
    p.unit_price                                    AS current_list_price,
    p.unit_cost,
    ROUND((p.unit_price - p.unit_cost) / NULLIF(p.unit_price, 0) * 100, 2) AS list_margin_pct,
    p.weight_kg,
    p.product_status,
    p.supplier_id,
    p.launch_date,
    p.last_restock_date,
    p.inventory_count,

    -- Sales performance
    NVL(ps.total_units_sold, 0)                     AS total_units_sold,
    NVL(ps.total_revenue, 0)                        AS total_revenue,
    NVL(ps.total_margin, 0)                         AS total_margin,
    NVL(ps.order_count, 0)                          AS order_count,
    NVL(ps.customer_count, 0)                       AS unique_customers,
    ps.first_sold_date,
    ps.last_sold_date,
    NVL(ps.avg_selling_price, p.unit_price)         AS avg_selling_price,
    NVL(ps.avg_discount_given, 0)                   AS avg_discount_given,

    -- Inventory status
    CASE
        WHEN p.inventory_count <= 0 THEN 'Out of Stock'
        WHEN p.inventory_count < 10 THEN 'Low Stock'
        WHEN p.inventory_count < 100 THEN 'Normal'
        ELSE 'Well Stocked'
    END                                             AS inventory_status,

    -- Days since last sale
    DATEDIFF(day, ps.last_sold_date, GETDATE())     AS days_since_last_sale,

    -- Product performance tier
    NTILE(4) OVER (ORDER BY NVL(ps.total_revenue, 0) DESC) AS revenue_quartile,

    GETDATE()                                       AS _loaded_at

FROM staging.stg_raw_products p
LEFT JOIN product_sales ps ON p.product_id = ps.product_id;

GRANT SELECT ON marts.dim_products TO GROUP analytics_readers;
GRANT SELECT ON marts.dim_products TO GROUP bi_team;
ANALYZE marts.dim_products;
