-- ============================================================
-- transforms.int_customer_sessions
-- Sessionizes clickstream events, computes session-level
-- metrics, and assigns first/last touch attribution.
-- ============================================================

DROP TABLE IF EXISTS transforms.int_customer_sessions;

CREATE TABLE transforms.int_customer_sessions
DISTKEY(user_id)
SORTKEY(session_start)
AS
WITH session_boundaries AS (
    -- Detect session breaks: gap > 30 minutes between events
    SELECT
        e.*,
        CASE
            WHEN DATEDIFF(minute, 
                LAG(event_timestamp) OVER (PARTITION BY user_id ORDER BY event_timestamp),
                event_timestamp
            ) > 30
            OR LAG(event_timestamp) OVER (PARTITION BY user_id ORDER BY event_timestamp) IS NULL
            THEN 1
            ELSE 0
        END AS is_new_session
    FROM staging.stg_raw_events e
    WHERE e.user_id IS NOT NULL
),

session_ids AS (
    SELECT
        *,
        SUM(is_new_session) OVER (
            PARTITION BY user_id 
            ORDER BY event_timestamp 
            ROWS UNBOUNDED PRECEDING
        ) AS session_seq
    FROM session_boundaries
),

session_agg AS (
    SELECT
        user_id,
        session_seq,
        MIN(session_id)                              AS session_id,
        MIN(event_timestamp)                         AS session_start,
        MAX(event_timestamp)                         AS session_end,
        DATEDIFF(second, MIN(event_timestamp), MAX(event_timestamp)) AS session_duration_sec,
        COUNT(*)                                     AS event_count,
        COUNT(DISTINCT page_url)                     AS pages_viewed,
        SUM(CASE WHEN event_type = 'purchase' THEN 1 ELSE 0 END) AS purchase_count,
        SUM(CASE WHEN event_type = 'add_to_cart' THEN 1 ELSE 0 END) AS add_to_cart_count,
        SUM(NVL(event_revenue, 0))                   AS session_revenue,
        
        -- First and last touch attribution
        FIRST_VALUE(referrer) OVER (
            PARTITION BY user_id, session_seq 
            ORDER BY event_timestamp 
            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        ) AS first_touch_referrer,
        LAST_VALUE(referrer) OVER (
            PARTITION BY user_id, session_seq 
            ORDER BY event_timestamp 
            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        ) AS last_touch_referrer,

        FIRST_VALUE(device_type) OVER (
            PARTITION BY user_id, session_seq 
            ORDER BY event_timestamp 
            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        ) AS device_type,

        FIRST_VALUE(country) OVER (
            PARTITION BY user_id, session_seq 
            ORDER BY event_timestamp 
            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        ) AS country

    FROM session_ids
    GROUP BY user_id, session_seq
)

SELECT
    user_id,
    session_id,
    session_seq,
    session_start,
    session_end,
    session_duration_sec,
    event_count,
    pages_viewed,
    purchase_count,
    add_to_cart_count,
    session_revenue,
    first_touch_referrer,
    last_touch_referrer,
    device_type,
    country,
    CASE 
        WHEN purchase_count > 0 THEN 'converted'
        WHEN add_to_cart_count > 0 THEN 'engaged'
        WHEN pages_viewed > 3 THEN 'browsing'
        ELSE 'bounced'
    END AS session_outcome,
    CASE 
        WHEN session_duration_sec < 10 THEN 'bounce'
        WHEN session_duration_sec < 120 THEN 'short'
        WHEN session_duration_sec < 600 THEN 'medium'
        ELSE 'long'
    END AS session_length_bucket,
    GETDATE() AS _loaded_at
FROM session_agg;

GRANT SELECT ON transforms.int_customer_sessions TO GROUP analytics_readers;
ANALYZE transforms.int_customer_sessions;
