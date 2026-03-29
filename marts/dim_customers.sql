-- ============================================================
-- marts.dim_customers
-- Customer dimension with segmentation, RFM scoring,
-- and lifetime value calculation.
-- ============================================================

DROP TABLE IF EXISTS marts.dim_customers;

CREATE TABLE marts.dim_customers
DISTKEY(customer_id)
SORTKEY(customer_id)
AS
WITH customer_orders AS (
    SELECT
        customer_id,
        COUNT(*)                                    AS total_orders,
        SUM(gross_revenue)                          AS lifetime_revenue,
        SUM(total_margin)                           AS lifetime_margin,
        MIN(order_date)                             AS first_order_date,
        MAX(order_date)                             AS last_order_date,
        AVG(gross_revenue)                          AS avg_order_value,
        APPROXIMATE COUNT(DISTINCT order_month)     AS active_months,
        SUM(CASE WHEN is_refunded THEN 1 ELSE 0 END) AS refund_count,
        SUM(total_units)                            AS total_units_purchased,
        MODE() WITHIN GROUP (ORDER BY order_channel) AS preferred_channel,
        MODE() WITHIN GROUP (ORDER BY payment_method) AS preferred_payment
    FROM marts.fct_orders
    GROUP BY customer_id
),

rfm AS (
    SELECT
        customer_id,
        DATEDIFF(day, last_order_date, GETDATE())   AS recency_days,
        total_orders                                 AS frequency,
        lifetime_revenue                             AS monetary,
        NTILE(5) OVER (ORDER BY DATEDIFF(day, last_order_date, GETDATE()) ASC)  AS r_score,
        NTILE(5) OVER (ORDER BY total_orders ASC)    AS f_score,
        NTILE(5) OVER (ORDER BY lifetime_revenue ASC) AS m_score
    FROM customer_orders
)

SELECT
    c.customer_id,
    c.email_hash,
    c.email_domain,
    c.first_name_masked,
    c.last_name_masked,
    c.country,
    c.state,
    c.city,
    c.postal_code_masked,
    c.registration_date,
    c.last_login_date,
    c.marketing_opt_in,
    c.loyalty_tier,
    c.days_since_registration,

    -- Order history
    NVL(co.total_orders, 0)                          AS total_orders,
    NVL(co.lifetime_revenue, 0)                      AS lifetime_revenue,
    NVL(co.lifetime_margin, 0)                       AS lifetime_margin,
    co.first_order_date,
    co.last_order_date,
    NVL(co.avg_order_value, 0)                       AS avg_order_value,
    NVL(co.active_months, 0)                         AS active_months,
    NVL(co.refund_count, 0)                          AS refund_count,
    NVL(co.total_units_purchased, 0)                 AS total_units_purchased,
    NVL(co.preferred_channel, 'none')                AS preferred_channel,
    NVL(co.preferred_payment, 'none')                AS preferred_payment,

    -- RFM scores
    NVL(r.r_score, 1)                                AS recency_score,
    NVL(r.f_score, 1)                                AS frequency_score,
    NVL(r.m_score, 1)                                AS monetary_score,
    NVL(r.r_score, 1) + NVL(r.f_score, 1) + NVL(r.m_score, 1) AS rfm_total,

    -- Customer segment
    CASE
        WHEN co.total_orders IS NULL THEN 'Never Purchased'
        WHEN r.r_score >= 4 AND r.f_score >= 4 AND r.m_score >= 4 THEN 'Champions'
        WHEN r.r_score >= 4 AND r.f_score >= 3 THEN 'Loyal Customers'
        WHEN r.r_score >= 4 AND r.f_score <= 2 THEN 'New Customers'
        WHEN r.r_score >= 3 AND r.f_score >= 3 THEN 'Potential Loyalists'
        WHEN r.r_score <= 2 AND r.f_score >= 3 THEN 'At Risk'
        WHEN r.r_score <= 2 AND r.f_score <= 2 AND r.m_score >= 3 THEN 'Cant Lose Them'
        WHEN r.r_score <= 2 AND r.f_score <= 2 THEN 'Hibernating'
        ELSE 'Other'
    END                                              AS customer_segment,

    -- Churn risk
    CASE
        WHEN co.total_orders IS NULL THEN 'no_purchase'
        WHEN DATEDIFF(day, co.last_order_date, GETDATE()) > 180 THEN 'high_risk'
        WHEN DATEDIFF(day, co.last_order_date, GETDATE()) > 90 THEN 'medium_risk'
        WHEN DATEDIFF(day, co.last_order_date, GETDATE()) > 30 THEN 'low_risk'
        ELSE 'active'
    END                                              AS churn_risk,

    -- Refund rate
    CASE
        WHEN NVL(co.total_orders, 0) > 0 
        THEN ROUND(NVL(co.refund_count, 0)::FLOAT / co.total_orders * 100, 2)
        ELSE 0
    END                                              AS refund_rate_pct,

    GETDATE()                                        AS _loaded_at

FROM staging.stg_raw_customers c
LEFT JOIN customer_orders co ON c.customer_id = co.customer_id
LEFT JOIN rfm r ON c.customer_id = r.customer_id;

GRANT SELECT ON marts.dim_customers TO GROUP analytics_readers;
GRANT SELECT ON marts.dim_customers TO GROUP bi_team;
ANALYZE marts.dim_customers;
