-- ============================================================
-- staging.stg_raw_products
-- Full refresh of the product catalog from the inventory system.
-- Handles SCD Type 1 (overwrite with latest).
-- ============================================================

BEGIN TRANSACTION;

DROP TABLE IF EXISTS staging.stg_raw_products_tmp;

CREATE TABLE staging.stg_raw_products_tmp
DISTSTYLE ALL
SORTKEY(product_id)
AS
SELECT
    CAST(p.id AS BIGINT)                           AS product_id,
    CAST(p.sku AS VARCHAR(50))                     AS sku,
    CAST(p.name AS VARCHAR(200))                   AS product_name,
    CAST(p.category AS VARCHAR(100))               AS category,
    CAST(p.subcategory AS VARCHAR(100))            AS subcategory,
    CAST(p.brand AS VARCHAR(100))                  AS brand,
    CAST(p.price AS DECIMAL(10,2))                 AS unit_price,
    CAST(p.cost AS DECIMAL(10,2))                  AS unit_cost,
    CAST(p.weight_kg AS DECIMAL(8,3))              AS weight_kg,
    CASE
        WHEN p.status = 'A' THEN 'Active'
        WHEN p.status = 'D' THEN 'Discontinued'
        WHEN p.status = 'O' THEN 'Out of Stock'
        ELSE 'Unknown'
    END                                            AS product_status,
    NVL(p.supplier_id, -1)                         AS supplier_id,
    CONVERT(DATE, p.launch_date)                   AS launch_date,
    CONVERT(DATE, p.last_restock_date)             AS last_restock_date,
    p.inventory_count,
    GETDATE()                                      AS _loaded_at
FROM spectrum.raw_products p
WHERE p.id IS NOT NULL
  AND p.name IS NOT NULL;

-- Swap tables
DROP TABLE IF EXISTS staging.stg_raw_products;
ALTER TABLE staging.stg_raw_products_tmp RENAME TO stg_raw_products;

COMMIT;

GRANT SELECT ON staging.stg_raw_products TO GROUP analytics_readers;
ANALYZE staging.stg_raw_products;
