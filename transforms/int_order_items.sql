-- ============================================================
-- transforms.int_order_items
-- Joins order line items with product data to compute
-- item-level revenue, margin, and discount metrics.
-- ============================================================

DROP TABLE IF EXISTS transforms.int_order_items;

CREATE TABLE transforms.int_order_items
DISTKEY(order_id)
SORTKEY(order_date, order_id)
AS
WITH order_items AS (
    SELECT
        CAST(oi.id AS BIGINT)                       AS order_item_id,
        CAST(oi.order_id AS BIGINT)                  AS order_id,
        CAST(oi.product_id AS BIGINT)                AS product_id,
        CAST(oi.quantity AS INT)                      AS quantity,
        CAST(oi.unit_price AS DECIMAL(10,2))          AS sold_unit_price,
        CAST(oi.discount_pct AS DECIMAL(5,2))         AS discount_pct,
        CAST(oi.line_total AS DECIMAL(12,2))          AS line_total
    FROM spectrum.raw_order_items oi
    WHERE oi.order_id IS NOT NULL
      AND oi.quantity > 0
),

enriched AS (
    SELECT
        oi.order_item_id,
        oi.order_id,
        oi.product_id,
        o.customer_id,
        o.order_date,
        o.order_status,
        o.order_channel,
        o.billing_country,
        o.payment_method,

        p.sku,
        p.product_name,
        p.category,
        p.subcategory,
        p.brand,
        p.unit_cost,

        oi.quantity,
        oi.sold_unit_price,
        oi.discount_pct,
        oi.line_total,

        -- Revenue metrics
        oi.line_total                                 AS gross_revenue,
        ROUND(oi.line_total * (1 - NVL(oi.discount_pct, 0) / 100.0), 2) 
                                                      AS net_revenue,
        ROUND(oi.quantity * NVL(p.unit_cost, 0), 2)   AS cogs,
        ROUND(oi.line_total - (oi.quantity * NVL(p.unit_cost, 0)), 2) 
                                                      AS gross_margin,
        CASE
            WHEN oi.line_total > 0 
            THEN ROUND((oi.line_total - (oi.quantity * NVL(p.unit_cost, 0))) 
                        / oi.line_total * 100, 2)
            ELSE 0
        END                                           AS margin_pct,

        -- Flags
        CASE WHEN oi.discount_pct > 0 THEN TRUE ELSE FALSE END AS is_discounted,
        CASE WHEN p.product_status = 'Discontinued' THEN TRUE ELSE FALSE END AS is_discontinued_product,

        GETDATE() AS _loaded_at

    FROM order_items oi
    INNER JOIN staging.stg_raw_orders o
        ON oi.order_id = o.order_id
    LEFT JOIN staging.stg_raw_products p
        ON oi.product_id = p.product_id
)

SELECT * FROM enriched;

GRANT SELECT ON transforms.int_order_items TO GROUP analytics_readers;
ANALYZE transforms.int_order_items;
