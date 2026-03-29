-- ============================================================
-- marts.fct_orders
-- Order-level fact table combining order header, line items,
-- customer data, and session attribution.
-- This is the primary table used by the BI team.
-- ============================================================

DROP TABLE IF EXISTS marts.fct_orders;

CREATE TABLE marts.fct_orders
DISTKEY(order_id)
SORTKEY(order_date)
AS
WITH order_metrics AS (
    SELECT
        order_id,
        COUNT(*)                                    AS item_count,
        COUNT(DISTINCT product_id)                  AS unique_products,
        COUNT(DISTINCT category)                    AS unique_categories,
        SUM(quantity)                               AS total_units,
        SUM(gross_revenue)                          AS gross_revenue,
        SUM(net_revenue)                            AS net_revenue,
        SUM(cogs)                                   AS total_cogs,
        SUM(gross_margin)                           AS total_margin,
        ROUND(AVG(margin_pct), 2)                   AS avg_margin_pct,
        SUM(CASE WHEN is_discounted THEN 1 ELSE 0 END) AS discounted_items,
        LISTAGG(DISTINCT category, ', ') WITHIN GROUP (ORDER BY category) AS categories_purchased
    FROM transforms.int_order_items
    GROUP BY order_id
),

-- Get the session that led to this order (last session before order)
order_attribution AS (
    SELECT
        o.order_id,
        o.customer_id,
        s.session_id                                AS converting_session_id,
        s.first_touch_referrer                      AS attribution_channel,
        s.device_type                               AS conversion_device,
        s.session_duration_sec                      AS conversion_session_duration,
        s.pages_viewed                              AS pre_purchase_pages,
        ROW_NUMBER() OVER (
            PARTITION BY o.order_id 
            ORDER BY s.session_start DESC
        ) AS _rn
    FROM staging.stg_raw_orders o
    LEFT JOIN transforms.int_customer_sessions s
        ON o.customer_id = s.user_id
        AND s.session_start <= o.order_timestamp
        AND s.session_start >= DATEADD(hour, -24, o.order_timestamp)
        AND s.purchase_count > 0
)

SELECT
    o.order_id,
    o.customer_id,
    o.order_number,
    o.order_date,
    o.order_timestamp,
    o.order_status,
    o.order_channel,
    o.payment_method,
    o.shipping_method,
    o.billing_country,
    o.shipping_country,
    o.coupon_code,

    -- Customer attributes (at time of order)
    c.loyalty_tier,
    c.country                                       AS customer_country,
    c.registration_date                             AS customer_since,
    DATEDIFF(day, c.registration_date, o.order_date) AS customer_tenure_days,
    CASE
        WHEN DATEDIFF(day, c.registration_date, o.order_date) <= 30 THEN 'New (0-30d)'
        WHEN DATEDIFF(day, c.registration_date, o.order_date) <= 90 THEN 'Growing (31-90d)'
        WHEN DATEDIFF(day, c.registration_date, o.order_date) <= 365 THEN 'Established (91-365d)'
        ELSE 'Loyal (365d+)'
    END                                             AS customer_lifecycle_stage,

    -- Order line item metrics
    m.item_count,
    m.unique_products,
    m.unique_categories,
    m.total_units,
    m.gross_revenue,
    m.net_revenue,
    m.total_cogs,
    m.total_margin,
    m.avg_margin_pct,
    m.discounted_items,
    m.categories_purchased,

    -- Shipping and tax from header
    o.shipping_amount,
    o.tax_amount,
    o.discount_amount                               AS header_discount,
    (o.total_amount)                                AS order_total,

    -- Attribution
    NVL(a.attribution_channel, 'unknown')           AS attribution_channel,
    NVL(a.conversion_device, 'unknown')             AS conversion_device,
    a.converting_session_id,
    a.conversion_session_duration,
    a.pre_purchase_pages,

    -- Order flags
    CASE WHEN o.coupon_code != 'NONE' THEN TRUE ELSE FALSE END AS used_coupon,
    CASE WHEN m.discounted_items > 0 THEN TRUE ELSE FALSE END AS has_discounted_items,
    CASE WHEN o.order_status = 'refunded' THEN TRUE ELSE FALSE END AS is_refunded,
    CASE WHEN o.shipping_country != o.billing_country THEN TRUE ELSE FALSE END AS is_international,

    -- Time dimensions
    DATE_PART(dow, o.order_date)                    AS day_of_week,
    DATE_PART(hour, o.order_timestamp)              AS hour_of_day,
    TO_CHAR(o.order_date, 'YYYY-MM')               AS order_month,
    DATE_PART(week, o.order_date)                   AS week_of_year,

    GETDATE()                                       AS _loaded_at

FROM staging.stg_raw_orders o
INNER JOIN order_metrics m
    ON o.order_id = m.order_id
LEFT JOIN staging.stg_raw_customers c
    ON o.customer_id = c.customer_id
LEFT JOIN order_attribution a
    ON o.order_id = a.order_id
    AND a._rn = 1
WHERE o.order_status NOT IN ('pending_payment', 'fraud_review');

GRANT SELECT ON marts.fct_orders TO GROUP analytics_readers;
GRANT SELECT ON marts.fct_orders TO GROUP bi_team;
ANALYZE marts.fct_orders;
