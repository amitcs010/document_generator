-- ============================================================
-- staging.stg_raw_customers
-- Ingests customer records from the CRM export (S3 CSV).
-- Deduplicates by customer_id, keeps the most recent record.
-- Masks PII fields for downstream analytics.
-- ============================================================

DROP TABLE IF EXISTS staging.stg_raw_customers;

CREATE TABLE staging.stg_raw_customers
DISTKEY(customer_id)
SORTKEY(customer_id)
AS
WITH ranked AS (
    SELECT
        CAST(c.id AS BIGINT)                        AS customer_id,
        CAST(c.email AS VARCHAR(256))                AS email_raw,
        CAST(c.first_name AS VARCHAR(100))           AS first_name,
        CAST(c.last_name AS VARCHAR(100))            AS last_name,
        CAST(c.phone AS VARCHAR(20))                 AS phone_raw,
        CAST(c.country AS VARCHAR(2))                AS country,
        CAST(c.state AS VARCHAR(50))                 AS state,
        CAST(c.city AS VARCHAR(100))                 AS city,
        CAST(c.postal_code AS VARCHAR(20))           AS postal_code,
        CONVERT(DATE, c.created_at)                  AS registration_date,
        CONVERT(DATE, c.last_login)                  AS last_login_date,
        NVL(c.marketing_opt_in, FALSE)               AS marketing_opt_in,
        NVL(c.loyalty_tier, 'Bronze')                AS loyalty_tier,
        CAST(c.lifetime_value AS DECIMAL(12,2))      AS reported_ltv,
        ROW_NUMBER() OVER (
            PARTITION BY c.id
            ORDER BY c.updated_at DESC
        ) AS _row_num
    FROM spectrum.raw_customers c
    WHERE c.id IS NOT NULL
      AND c.email IS NOT NULL
      AND LEN(c.email) > 3
)
SELECT
    customer_id,
    -- PII masking: hash email, keep domain for analytics
    MD5(LOWER(TRIM(email_raw)))                      AS email_hash,
    SPLIT_PART(email_raw, '@', 2)                    AS email_domain,
    LEFT(first_name, 1) || '***'                     AS first_name_masked,
    LEFT(last_name, 1) || '***'                      AS last_name_masked,
    -- Keep only country code from phone
    LEFT(phone_raw, 3)                               AS phone_country_prefix,
    country,
    state,
    city,
    LEFT(postal_code, 3) || '***'                    AS postal_code_masked,
    registration_date,
    last_login_date,
    marketing_opt_in,
    loyalty_tier,
    NVL(reported_ltv, 0)                             AS reported_ltv,
    DATEDIFF(day, registration_date, GETDATE())      AS days_since_registration,
    GETDATE()                                        AS _loaded_at
FROM ranked
WHERE _row_num = 1;

GRANT SELECT ON staging.stg_raw_customers TO GROUP analytics_readers;
ANALYZE staging.stg_raw_customers;
