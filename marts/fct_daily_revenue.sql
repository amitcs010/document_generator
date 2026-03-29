-- ============================================================
-- marts.fct_daily_revenue
-- Daily revenue rollup by product category, channel, and country.
-- Used by the executive dashboard and finance team.
-- ============================================================

DROP TABLE IF EXISTS marts.fct_daily_revenue;

CREATE TABLE marts.fct_daily_revenue
DISTKEY(revenue_date)
SORTKEY(revenue_date, category)
AS
SELECT
    o.order_date                                    AS revenue_date,
    oi.category,
    oi.subcategory,
    oi.brand,
    o.order_channel,
    o.billing_country,
    o.payment_method,

    -- Volume metrics
    COUNT(DISTINCT o.order_id)                      AS order_count,
    COUNT(DISTINCT o.customer_id)                   AS customer_count,
    SUM(oi.quantity)                                AS units_sold,
    COUNT(DISTINCT oi.product_id)                   AS unique_products_sold,

    -- Revenue metrics
    SUM(oi.gross_revenue)                           AS gross_revenue,
    SUM(oi.net_revenue)                             AS net_revenue,
    SUM(oi.cogs)                                    AS cogs,
    SUM(oi.gross_margin)                            AS gross_margin,
    ROUND(
        CASE WHEN SUM(oi.gross_revenue) > 0 
            THEN SUM(oi.gross_margin) / SUM(oi.gross_revenue) * 100 
            ELSE 0 
        END, 2
    )                                               AS margin_pct,

    -- Averages
    ROUND(SUM(oi.gross_revenue) / NULLIF(COUNT(DISTINCT o.order_id), 0), 2) AS avg_order_value,
    ROUND(SUM(oi.gross_revenue) / NULLIF(SUM(oi.quantity), 0), 2) AS avg_unit_price,

    -- Discount metrics
    SUM(CASE WHEN oi.is_discounted THEN oi.gross_revenue ELSE 0 END) AS discounted_revenue,
    ROUND(
        SUM(CASE WHEN oi.is_discounted THEN oi.gross_revenue ELSE 0 END) 
        / NULLIF(SUM(oi.gross_revenue), 0) * 100, 2
    )                                               AS discount_revenue_pct,

    -- Comparison helpers
    SUM(oi.gross_revenue) - LAG(SUM(oi.gross_revenue), 1) OVER (
        PARTITION BY oi.category, o.order_channel
        ORDER BY o.order_date
    )                                               AS revenue_vs_prev_day,

    SUM(oi.gross_revenue) - LAG(SUM(oi.gross_revenue), 7) OVER (
        PARTITION BY oi.category, o.order_channel
        ORDER BY o.order_date
    )                                               AS revenue_vs_prev_week,

    GETDATE()                                       AS _loaded_at

FROM transforms.int_order_items oi
INNER JOIN staging.stg_raw_orders o
    ON oi.order_id = o.order_id
WHERE o.order_status NOT IN ('pending_payment', 'fraud_review', 'cancelled')
GROUP BY 
    o.order_date,
    oi.category,
    oi.subcategory,
    oi.brand,
    o.order_channel,
    o.billing_country,
    o.payment_method;

GRANT SELECT ON marts.fct_daily_revenue TO GROUP analytics_readers;
GRANT SELECT ON marts.fct_daily_revenue TO GROUP bi_team;
GRANT SELECT ON marts.fct_daily_revenue TO GROUP finance_team;
ANALYZE marts.fct_daily_revenue;
