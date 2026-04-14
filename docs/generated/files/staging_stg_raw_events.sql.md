# staging/stg_raw_events.sql

## Component Overview
- **Layer:** Staging
- **Type:** Table (materialized)
- **Schedule:** Not specified in code (infer from orchestration system)
- **Owner:** Not specified in code (infer from team documentation)

---

## Purpose

This component ingests raw clickstream events from the event bus and prepares them for downstream analytics consumption. It parses semi-structured JSON payloads into clean, typed columns and removes duplicate events that may arrive multiple times from the source system. The output serves as the single source of truth for all event-based analytics, powering user behavior analysis, funnel reporting, and product metrics.

---

## Inputs

- **spectrum.raw_clickstream** — External event bus table containing raw JSON-encoded clickstream events. Provides the authoritative stream of user interactions (page views, clicks, purchases, etc.) with embedded metadata. This component depends on it as the only source of event truth; data quality and schema stability of this table directly impact all downstream analytics.

---

## Outputs

- **staging.stg_raw_events** — Cleaned, deduplicated event table with parsed columns and standardized data types. Consumed by mart and reporting layers to build user funnels, session analysis, product performance dashboards, and customer segmentation models. This is a critical dependency for all event-based analytics.

---

## Key Business Logic

### 1. **JSON Payload Parsing**
Raw events arrive as JSON strings in the `payload` column. The code extracts 11 distinct fields (user_id, session_id, event_type, etc.) using `JSON_EXTRACT_PATH_TEXT()`. This denormalization makes the data queryable and enables downstream joins with user and product dimensions.

### 2. **Deduplication by Event ID**
Events may be delivered multiple times by the source system (at-least-once delivery semantics). The code uses `ROW_NUMBER() OVER (PARTITION BY event_id ORDER BY event_time DESC)` to identify duplicates and retains only the most recent occurrence (`WHERE _row_num = 1`). This ensures each event is counted exactly once in downstream metrics.

### 3. **3-Day Lookback Window**
The filter `WHERE event_time >= DATEADD(day, -3, GETDATE())` limits ingestion to the last 3 days of events. This is a performance optimization (reduces scan volume) and implies the table is refreshed frequently (likely daily). Older events are assumed to be archived elsewhere or already processed.

### 4. **Type Casting & Standardization**
- `user_id` and `product_id` are cast to `BIGINT` to enable efficient joins with dimension tables.
- `event_revenue` is cast to `DECIMAL(12,2)` to preserve monetary precision (cents).
- `event_time` is converted to a proper `TIMESTAMP` type for time-series operations.

### 5. **Null Handling with Business Defaults**
- `referrer` defaults to `'direct'` if null (business rule: unattributed traffic is assumed direct).
- `device_type` defaults to `'unknown'` if null (preserves rows rather than filtering them out).
- `event_revenue` defaults to `0` if null (non-revenue events are treated as zero-value transactions).

These defaults prevent data loss and ensure all events are retained for funnel analysis, even if some attributes are missing.

### 6. **Timestamp Standardization**
The `_loaded_at` column captures the ETL execution time (`GETDATE()`), enabling data freshness monitoring and debugging of late-arriving events.

---

## Column Descriptions

| Column | Type | Description | Example Values |
|--------|------|-------------|-----------------|
| **event_id** | VARCHAR | Unique identifier for the event, assigned by the source system. Primary deduplication key. | `evt_a1b2c3d4e5f6` |
| **user_id** | BIGINT | Internal user identifier, cast from JSON string. Used to join with user dimension tables. | `12345`, `67890` |
| **session_id** | VARCHAR | Session identifier grouping events from a single user visit. Enables session-level aggregations (e.g., session duration, pages per session). | `sess_xyz789` |
| **event_type** | VARCHAR | Categorical event classification. Common values: `page_view`, `click`, `add_to_cart`, `purchase`, `search`. Used for funnel analysis and event filtering. | `purchase`, `page_view` |
| **page_url** | VARCHAR | Full URL of the page where the event occurred. Enables page-level analysis and traffic source attribution. | `https://example.com/products/shoes` |
| **referrer** | VARCHAR | HTTP referrer URL or `'direct'` if null. Indicates traffic source (organic search, paid ads, social, direct). | `https://google.com`, `direct` |
| **device_type** | VARCHAR | Device category or `'unknown'` if null. Values: `mobile`, `desktop`, `tablet`. Used for device-specific reporting and mobile conversion analysis. | `mobile`, `desktop` |
| **browser** | VARCHAR | Browser name/version extracted from user agent. Used for browser compatibility analysis and debugging. | `Chrome 120`, `Safari 17` |
| **country** | VARCHAR | ISO country code or country name derived from IP geolocation. Enables geographic segmentation and regional performance analysis. | `US`, `GB`, `DE` |
| **product_id** | BIGINT | Internal product identifier, cast from JSON string. Enables joins with product dimension for product-level metrics. | `5001`, `5002` |
| **event_revenue** | DECIMAL(12,2) | Revenue attributed to the event in USD (or base currency). Null values default to `0`. Used for revenue attribution and AOV calculations. | `29.99`, `0.00` |
| **event_timestamp** | TIMESTAMP | Event occurrence time in UTC. Enables time-series analysis, cohort analysis, and temporal joins. | `2024-01-15 14:32:45.123` |
| **_loaded_at** | TIMESTAMP | ETL execution timestamp. Used for data freshness monitoring and identifying late-arriving events. | `2024-01-15 15:00:00.000` |

---

## Data Quality & Edge Cases

### Null Handling Strategy
- **Referrer:** Null values are replaced with `'direct'` (business assumption: unattributed traffic is direct).
- **Device Type:** Null values are replaced with `'unknown'` (preserves row rather than filtering).
- **Event Revenue:** Null values are replaced with `0` (non-revenue events are zero-value).
- **Other columns** (user_id, session_id, event_type, page_url, browser, country, product_id): Null values are preserved as-is. Downstream consumers must handle nulls or apply their own business rules.

### Deduplication Strategy
- **Method:** `ROW_NUMBER() OVER (PARTITION BY event_id ORDER BY event_time DESC)` retains the most recent occurrence of each event_id.
- **Assumption:** If duplicates exist, the most recent timestamp is the authoritative version.
- **Risk:** If the source system reorders events (e.g., late-arriving corrections), the wrong version may be retained. Mitigate by validating event_id uniqueness in source system.

### Key Assumptions About Upstream Data
1. **event_id is globally unique** within the source system (or duplicates are intentional retries).
2. **event_time is always present and valid** (code filters `WHERE event_id IS NOT NULL` but not event_time).
3. **JSON payload structure is consistent** — all expected keys exist (missing keys return null, which is handled).
4. **Revenue values are pre-validated** in the source system (code assumes valid DECIMAL format).
5. **3-day lookback is sufficient** — no business requirement for events older than 3 days in this table.

### What Could Break If Upstream Data Changes

| Scenario | Impact | Mitigation |
|----------|--------|-----------|
| **JSON schema changes** (new/removed keys) | New fields silently ignored; removed fields become null. Downstream queries may fail if they expect non-null values. | Add schema validation in source system; alert on unexpected null rates. |
| **event_id collisions** | Duplicates not deduplicated; metrics double-counted. | Validate event_id uniqueness in source system; add uniqueness constraint to staging table. |
| **event_time missing or invalid** | Rows with invalid timestamps fail CONVERT(); entire load fails. | Add NOT NULL constraint and timestamp validation in source system. |
| **Payload encoding changes** (e.g., nested JSON) | JSON_EXTRACT_PATH_TEXT() fails on nested structures; returns null. | Document expected JSON structure; add schema validation. |
| **Revenue format changes** (e.g., string with currency symbol) | CAST to DECIMAL fails; entire load fails. | Enforce numeric format in source system; add data type validation. |
| **Lookback window too short** | Late-arriving events (>3 days old) are never ingested. | Monitor for late arrivals; adjust lookback window or implement late-arrival handling. |

---

## Performance Notes

### Distribution & Sorting Strategy
- **DISTKEY(event_id):** Events are distributed across nodes by event_id. This is optimal for deduplication (all duplicates co-locate on same node) and for downstream joins on event_id.
- **SORTKEY(event_timestamp):** Events are sorted by timestamp within each node. This accelerates time-range queries (e.g., "events in last 7 days") and enables efficient range scans for incremental loads.
- **Implication:** Queries filtering by event_timestamp will be fast; queries filtering by user_id or product_id will require full table scans (consider adding secondary sort keys if these are common access patterns).

### Expensive Operations
1. **JSON_EXTRACT_PATH_TEXT() × 11 columns:** Parsing JSON is CPU-intensive. If payload is large or deeply nested, this could be a bottleneck. Mitigate by pre-parsing in source system or using native JSON columns (if Redshift supports).
2. **ROW_NUMBER() window function:** Requires sorting all events by event_id and event_time. For large event volumes, this is expensive. Mitigate by filtering to 3-day lookback (already done).
3. **CAST operations:** Type conversions are generally fast but can fail on malformed data. Mitigate by validating data types in source system.

### Full Table Scans
- The 3-day lookback filter (`WHERE event_time >= DATEADD(day, -3, GETDATE())`) is applied *before* the window function, so the window function only processes 3 days of data (not the entire table). This is efficient.
- However, if the table grows unbounded, future queries on this table will scan all rows unless they also filter by event_timestamp. Consider partitioning by date if the table exceeds 10GB.

### Estimated Row Volume & Storage
- Assuming ~1M events/day, 3-day lookback = ~3M rows.
- With 13 columns (mostly VARCHAR/BIGINT), estimate ~500MB–1GB uncompressed.
- Redshift compression (typically 4–10x) reduces to ~50–250MB.
- ANALYZE command updates table statistics for query planner optimization.

---

## Dependencies

### Upstream (Must Run Before This Component)
- **spectrum.raw_clickstream** — Source table must be populated by event ingestion pipeline. No explicit dependency on other staging/mart tables.

### Downstream (Components That Depend on This Output)
- **mart.fct_events** — Fact table for event-level analytics; joins stg_raw_events with user and product dimensions.
- **mart.fct_sessions** — Session-level aggregations; groups stg_raw_events by session_id.
- **mart.fct_user_behavior** — User cohort analysis; aggregates stg_raw_events by user_id and event_type.
- **reports.dashboard_funnel** — Funnel analysis dashboard; filters stg_raw_events by event_type sequence.
- **reports.dashboard_product_performance** — Product metrics; joins stg_raw_events with product dimension on product_id.
- **ml_features.user_engagement_features** — ML feature engineering; aggregates stg_raw_events for user engagement scores.

### External Dependencies
- **spectrum.raw_clickstream** — External event bus (Kafka, Kinesis, or similar). Schema and delivery guarantees must be documented separately.
- **analytics_readers group** — IAM/permission group for downstream consumers. Grant statement assumes this group exists in Redshift.

### Orchestration & Scheduling
- **Not specified in code.** Infer from orchestration tool (Airflow, dbt, Glue, etc.):
  - If daily refresh: schedule after event ingestion completes (typically 1–2 hours after midnight UTC).
  - If real-time: consider streaming ingestion instead of batch.
  - If incremental: modify code to use `INSERT INTO` with date filter instead of `DROP TABLE` + `CREATE TABLE AS`.

---

## Maintenance & Monitoring Checklist

- [ ] **Monitor null rates** for each column; alert if nulls exceed baseline (e.g., >5% for device_type).
- [ ] **Monitor deduplication rate** (compare row count before/after deduplication); alert if duplicates spike.
- [ ] **Monitor load time** (ANALYZE output); alert if >5 minutes (indicates upstream data quality issues).
- [ ] **Validate event_id uniqueness** in source system; add uniqueness constraint if possible.
- [ ] **Document JSON schema** for payload; version control and alert on schema changes.
- [ ] **Test edge cases:** null referrer, missing product_id, invalid revenue format, timestamps >3 days old.
- [ ] **Review 3-day lookback window** annually; adjust if business requirements change (e.g., need for historical reprocessing).