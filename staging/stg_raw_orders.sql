-- ============================================================
-- staging.stg_raw_orders
-- Ingests raw order data from S3 parquet files into Redshift,
-- cleans column types, and filters out test orders.
-- Schedule: Daily at 02:00 UTC
-- Owner: Data Engineering
-- ============================================================

DROP TABLE IF EXISTS staging.stg_raw_orders;

CREATE TABLE staging.stg_raw_orders
DISTKEY(order_id)
SORTKEY(order_date)
AS
SELECT
    CAST(o.id AS BIGINT)                          AS order_id,
    CAST(o.customer_id AS BIGINT)                 AS customer_id,
    CAST(o.order_number AS VARCHAR(50))            AS order_number,
    CAST(o.status AS VARCHAR(20))                  AS order_status,
    CONVERT(DATE, o.created_at)                    AS order_date,
    CONVERT(TIMESTAMP, o.created_at)               AS order_timestamp,
    CONVERT(TIMESTAMP, o.updated_at)               AS updated_at,
    CAST(o.total_amount AS DECIMAL(12,2))          AS total_amount,
    CAST(o.discount_amount AS DECIMAL(12,2))       AS discount_amount,
    CAST(o.shipping_amount AS DECIMAL(12,2))       AS shipping_amount,
    CAST(o.tax_amount AS DECIMAL(12,2))            AS tax_amount,
    NVL(o.coupon_code, 'NONE')                     AS coupon_code,
    CAST(o.payment_method AS VARCHAR(30))           AS payment_method,
    CAST(o.shipping_method AS VARCHAR(30))          AS shipping_method,
    CAST(o.billing_country AS VARCHAR(2))           AS billing_country,
    CAST(o.shipping_country AS VARCHAR(2))          AS shipping_country,
    NVL(o.channel, 'web')                          AS order_channel,
    GETDATE()                                      AS _loaded_at
FROM
    spectrum.raw_orders o
WHERE
    o.created_at >= DATEADD(day, -3, GETDATE())    -- rolling 3-day window
    AND o.is_test = FALSE
    AND o.status != 'cancelled_by_system'
    AND o.total_amount > 0;

-- Grant access
GRANT SELECT ON staging.stg_raw_orders TO GROUP analytics_readers;

ANALYZE staging.stg_raw_orders;
