# staging/stg_raw_events.sql

## Component Overview
- **Layer:** Staging
- **Type:** Table (materialized)
- **Schedule:** Not specified in code; inferred to run frequently (likely hourly or daily based on 3-day lookback window)
- **Owner:** Not specified in code; likely Data Engineering or Analytics Engineering team

---

## Purpose

This component ingests raw clickstream events from the event bus and transforms them into a clean, deduplicated staging table ready for downstream analytics. It parses semi-structured JSON payloads into typed columns, applies business-critical deduplication logic, and enforces data quality standards (null handling, type casting). The output serves as the single source of truth for all event-based analytics, powering user behavior analysis, conversion funnels, and product metrics.

---

## Inputs

- **spectrum.raw_clickstream** — External event bus table containing raw clickstream events in JSON format. Provides the authoritative stream of user interactions (page views, clicks, transactions) with embedded metadata (user ID, session ID, device info, revenue). This component depends on it as the only upstream source; data freshness and schema stability are critical.

---

## Outputs

- **staging.stg_raw_events** — Cleaned, deduplicated event table with parsed columns and enforced data types. Consumed by downstream fact tables (e.g., `marts.fct_events`), user behavior models, and ad-hoc analytics queries. Serves as the foundation for session analysis, attribution modeling, and product analytics dashboards.

---

## Key Business Logic

### 1. **JSON Payload Parsing**
Raw events arrive as JSON blobs in the `payload` column. The component extracts 11 key fields (user_id, session_id, event_type, page_url, etc.) using `JSON_EXTRACT_PATH_TEXT()`. This denormalization makes data queryable and enables downstream joins on user/session/product dimensions.

### 2. **Deduplication by Event ID**
Events may arrive multiple times due to network retries, message queue reprocessing, or ETL reruns. The component uses `ROW_NUMBER() OVER (PARTITION BY event_id ORDER BY event_time DESC)` to identify duplicates and retains only the most recent occurrence (`WHERE _row_num = 1`). This ensures each event_id appears exactly once, preventing double-counting in metrics.

### 3. **Recency Filtering (3-Day Lookback)**
`WHERE event_time >= DATEADD(day, -3, GETDATE())` limits ingestion to the last 3 days. This is a performance optimization (reduces table size and scan time) and assumes:
- Historical events older than 3 days are already materialized elsewhere, OR
- Real-time analytics only require recent data, OR
- A separate batch process handles historical backfill.
- **Risk:** If downstream processes need older data, this filter will cause data loss.

### 4. **Null Handling with Business Defaults**
- `referrer`: Defaults to `'direct'` if null (assumes direct traffic if source is unknown)
- `device_type`: Defaults to `'unknown'` if null (preserves data integrity while flagging incomplete records)
- `event_revenue`: Defaults to `0` if null (assumes no revenue event if not explicitly provided)

These defaults prevent null propagation downstream but may mask data quality issues; consider logging nulls separately for monitoring.

### 5. **Type Casting**
- `user_id` and `product_id` cast to `BIGINT` (assumes IDs are numeric; will fail if non-numeric values exist)
- `event_revenue` cast to `DECIMAL(12,2)` (enforces 2-decimal precision for currency; truncates or rounds excess decimals)
- `event_timestamp` converted from string to `TIMESTAMP` (assumes ISO 8601 or Redshift-compatible format)

---

## Column Descriptions

| Column | Data Type | Description | Example Values |
|--------|-----------|-------------|-----------------|
| **event_id** | VARCHAR | Unique identifier for the event; primary deduplication key. Sourced from raw payload. | `evt_20240115_a7f2e9c1` |
| **user_id** | BIGINT | Numeric user identifier; enables user-level aggregations and joins to user dimension. | `12345`, `98765` |
| **session_id** | VARCHAR | Session identifier; groups events into user sessions for funnel and cohort analysis. | `sess_20240115_xyz789` |
| **event_type** | VARCHAR | Categorical event classification (e.g., 'page_view', 'add_to_cart', 'purchase'). Drives event-level filtering and metrics. | `'page_view'`, `'purchase'`, `'click'` |
| **page_url** | VARCHAR | Full URL of the page where event occurred; enables page-level analysis and traffic source attribution. | `'https://example.com/products/shoes'` |
| **referrer** | VARCHAR | HTTP referrer or traffic source; defaults to `'direct'` if null. Used for attribution and channel analysis. | `'direct'`, `'google.com'`, `'facebook.com'` |
| **device_type** | VARCHAR | Device category; defaults to `'unknown'` if null. Enables device-level segmentation (mobile vs. desktop). | `'mobile'`, `'desktop'`, `'tablet'`, `'unknown'` |
| **browser** | VARCHAR | Browser name/version; enables browser-specific debugging and compatibility analysis. | `'Chrome 121'`, `'Safari 17'` |
| **country** | VARCHAR | Geographic location (ISO country code or name); enables geo-segmentation and regional metrics. | `'US'`, `'GB'`, `'DE'` |
| **product_id** | BIGINT | Numeric product identifier; enables product-level metrics and joins to product catalog. | `5001`, `9999` |
| **event_revenue** | DECIMAL(12,2) | Revenue attributed to event (e.g., transaction amount); defaults to `0` if null. Used for revenue metrics and AOV calculations. | `29.99`, `0.00`, `149.50` |
| **event_timestamp** | TIMESTAMP | Timestamp when event occurred (server-side); used for time-series analysis and event ordering. | `2024-01-15 14:32:45.123` |
| **_loaded_at** | TIMESTAMP | Timestamp when record was loaded into staging; enables freshness monitoring and SLA tracking. | `2024-01-15 15:00:00.000` |

---

## Data Quality & Edge Cases

### Null Handling
- **Referrer, device_type, event_revenue:** Explicitly coalesced to business defaults (`'direct'`, `'unknown'`, `0`). This prevents nulls from propagating but may mask upstream data quality issues.
- **Other columns (user_id, session_id, event_type, page_url, browser, country, product_id):** Nulls are preserved. Downstream processes must handle these gracefully or filter them out.
- **Recommendation:** Add a data quality check to log the count of nulls per column; alert if null rates exceed thresholds (e.g., >5% for critical fields).

### Deduplication Strategy
- **Method:** `ROW_NUMBER() OVER (PARTITION BY event_id ORDER BY event_time DESC)` retains the most recent occurrence.
- **Assumption:** Later arrivals are more complete/accurate than earlier ones. If this is false (e.g., corrections arrive out-of-order), this logic may retain stale data.
- **Risk:** If event_id is not truly unique upstream (e.g., IDs are reused across days), deduplication may incorrectly merge unrelated events.
- **Recommendation:** Validate that event_id is globally unique; consider adding event_time to the deduplication key if events can legitimately occur multiple times.

### Type Casting Risks
- **user_id, product_id as BIGINT:** Will fail if non-numeric values exist (e.g., `'user_abc'`). No error handling; the entire load will fail.
- **event_revenue as DECIMAL(12,2):** Silently truncates/rounds values with >2 decimal places. May cause revenue discrepancies if source data has higher precision.
- **event_timestamp conversion:** Assumes ISO 8601 or Redshift-compatible format. Will fail if timestamps are in unexpected formats (e.g., Unix epoch milliseconds).
- **Recommendation:** Add pre-validation step to check data types before casting; log/quarantine invalid records rather than failing the entire load.

### Assumptions About Upstream Data
1. **event_id is unique:** If duplicates exist with different payloads, only the latest is retained; earlier versions are lost.
2. **event_time is reliable:** Deduplication and recency filtering depend on accurate timestamps. Clock skew or out-of-order arrivals may cause incorrect deduplication.
3. **JSON schema is stable:** If new fields are added or existing fields are renamed, extraction will silently return nulls. No schema validation occurs.
4. **3-day lookback is sufficient:** Assumes no backfill or late-arriving data older than 3 days. If historical corrections arrive late, they will be missed.

### What Could Break
- **Upstream schema changes:** If `payload` structure changes (e.g., `user_id` → `userId`), extraction returns nulls; downstream processes may fail silently.
- **Non-numeric IDs:** If user_id or product_id contain non-numeric values, the CAST will fail and the entire load will abort.
- **Timestamp format changes:** If event_time format changes, CONVERT will fail.
- **Null explosion:** If upstream null rates spike (e.g., device_type becomes 90% null), defaults may mask a real data quality issue.
- **Duplicate event_ids with different data:** If the same event_id arrives with conflicting payloads, only the latest is retained; earlier versions are lost without audit trail.

---

## Performance Notes

### Distribution & Sorting Strategy
- **DISTKEY(event_id):** Distributes rows across cluster nodes by event_id. This is optimal for:
  - Deduplication (all duplicates of an event_id co-locate on the same node, reducing network traffic during `ROW_NUMBER()` window function)
  - Downstream joins on event_id (reduces cross-node shuffles)
- **SORTKEY(event_timestamp):** Sorts rows within each node by event_timestamp. Benefits:
  - Time-range queries (e.g., "events in last 24 hours") can use zone maps for early pruning
  - Chronological scans are efficient
- **Trade-off:** Sorting on event_timestamp means inserts/updates require re-sorting; if this table is frequently updated, consider sorting on event_id instead.

### Window Function Performance
- `ROW_NUMBER() OVER (PARTITION BY event_id ORDER BY event_time DESC)` is a distributed window function. Performance depends on:
  - **Cardinality of event_id:** If most event_ids are unique (low duplicates), the window function is cheap. If many duplicates exist, it's expensive.
  - **Cluster size:** Larger clusters parallelize the window function better.
- **Optimization:** If duplicate rates are very low (<1%), consider removing deduplication or moving it to a separate step.

### Full Table Scan
- `DROP TABLE IF EXISTS ... CREATE TABLE ... AS` performs a full scan of `spectrum.raw_clickstream` (filtered to 3 days). This is unavoidable but:
  - Spectrum is external storage (S3), so scans are slower than Redshift native tables.
  - The 3-day filter reduces data volume significantly (assuming events are uniformly distributed).
- **Optimization:** If raw_clickstream is very large, consider partitioning it by date in S3 and using Spectrum partition pruning.

### JSON Extraction Overhead
- `JSON_EXTRACT_PATH_TEXT()` is called 11 times per row. JSON parsing is CPU-intensive.
- **Optimization:** If raw_clickstream is stored in columnar format (Parquet), consider using native column extraction instead of JSON parsing.

### Table Size & Maintenance
- **Estimated size:** Depends on event volume. If 1M events/day, 3-day lookback = ~3M rows. Typical row size ~500 bytes = ~1.5 GB (manageable).
- **ANALYZE:** The final `ANALYZE` statement updates table statistics for query planner. This is good practice but adds ~1-2 minutes to load time.

---

## Dependencies

### Upstream
- **spectrum.raw_clickstream** — External Redshift Spectrum table pointing to S3 clickstream data. Must exist and contain `event_id`, `payload` (JSON), and `event_time` columns. No SLA specified; assume best-effort delivery with potential duplicates and out-of-order arrivals.

### Downstream
- **marts.fct_events** — Fact table that likely joins this staging table with dimension tables (users, sessions, products) to create a conformed event fact table.
- **marts.fct_user_sessions** — Session-level fact table that aggregates events by session_id.
- **Ad-hoc analytics queries** — Analysts query this table directly for exploratory analysis, funnel analysis, and cohort studies.
- **BI dashboards** — Product analytics dashboards likely source event data from this table (directly or via marts).
- **ML feature engineering** — User behavior features (e.g., "events per session", "revenue per user") are derived from this table.

### External
- **analytics_readers group** — Redshift IAM/role group granted SELECT permissions. Ensures only authorized users/services can query this table.
- **Redshift cluster** — Assumes Redshift cluster is running and Spectrum is configured to access S3.
- **S3 (via Spectrum)** — Raw clickstream data is stored in S3; Spectrum provides the external table interface.

### Implicit Assumptions
- **ETL orchestration tool** (Airflow, dbt, etc.) runs this script on a schedule; no schedule is hardcoded in the SQL.
- **Data warehouse admin** has created the `staging` schema and granted permissions to `analytics_readers` group.
- **Monitoring/alerting** system tracks table freshness and row counts (not implemented in this script).

---

## Recommendations for Improvement

1. **Add data quality checks:** Log null counts, duplicate counts, and type conversion failures to a monitoring table.
2. **Parameterize the 3-day lookback:** Use a variable or config table instead of hardcoding `DATEADD(day, -3, GETDATE())` to enable flexible backfill.
3. **Add error handling:** Wrap type casts in TRY/CATCH to quarantine invalid records instead of failing the entire load.
4. **Document the deduplication assumption:** Add a comment explaining why the most recent event is retained (vs. earliest or a merge strategy).
5. **Consider incremental loading:** Instead of full table recreation, use UPSERT or merge logic to only load new/changed events (faster, lower resource usage).
6. **Add audit columns:** Track which events were deduplicated and why (e.g., `_duplicate_count`, `_dedup_reason`).