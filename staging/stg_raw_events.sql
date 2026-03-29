-- ============================================================
-- staging.stg_raw_events
-- Ingests raw clickstream events from the event bus.
-- Parses JSON payload, deduplicates by event_id.
-- ============================================================

DROP TABLE IF EXISTS staging.stg_raw_events;

CREATE TABLE staging.stg_raw_events
DISTSTYLE KEY
DISTKEY(event_id)
SORTKEY(event_timestamp)
AS
WITH raw_events AS (
    SELECT
        event_id,
        JSON_EXTRACT_PATH_TEXT(payload, 'user_id')          AS user_id,
        JSON_EXTRACT_PATH_TEXT(payload, 'session_id')        AS session_id,
        JSON_EXTRACT_PATH_TEXT(payload, 'event_type')        AS event_type,
        JSON_EXTRACT_PATH_TEXT(payload, 'page_url')          AS page_url,
        JSON_EXTRACT_PATH_TEXT(payload, 'referrer')          AS referrer,
        JSON_EXTRACT_PATH_TEXT(payload, 'device_type')       AS device_type,
        JSON_EXTRACT_PATH_TEXT(payload, 'browser')           AS browser,
        JSON_EXTRACT_PATH_TEXT(payload, 'country')           AS country,
        JSON_EXTRACT_PATH_TEXT(payload, 'product_id')        AS product_id,
        CAST(JSON_EXTRACT_PATH_TEXT(payload, 'revenue') AS DECIMAL(12,2)) AS event_revenue,
        CONVERT(TIMESTAMP, event_time)                       AS event_timestamp,
        GETDATE()                                            AS _loaded_at,
        ROW_NUMBER() OVER (
            PARTITION BY event_id 
            ORDER BY event_time DESC
        ) AS _row_num
    FROM spectrum.raw_clickstream
    WHERE event_time >= DATEADD(day, -3, GETDATE())
      AND event_id IS NOT NULL
)
SELECT
    event_id,
    CAST(user_id AS BIGINT)         AS user_id,
    session_id,
    event_type,
    page_url,
    NVL(referrer, 'direct')         AS referrer,
    NVL(device_type, 'unknown')     AS device_type,
    browser,
    country,
    CAST(product_id AS BIGINT)      AS product_id,
    NVL(event_revenue, 0)           AS event_revenue,
    event_timestamp,
    _loaded_at
FROM raw_events
WHERE _row_num = 1;

GRANT SELECT ON staging.stg_raw_events TO GROUP analytics_readers;
ANALYZE staging.stg_raw_events;
