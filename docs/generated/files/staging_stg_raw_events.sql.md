# stg_raw_events Documentation

**Purpose**
Staging layer that ingests raw clickstream events from the event bus, parses JSON payloads into structured columns, deduplicates records by event_id, and applies data quality transformations including type casting and null handling. Serves as the foundation for downstream analytics on user behavior and transactions.

**Inputs**
- `spectrum.raw_clickstream` – External Spectrum table containing raw JSON event payloads and metadata

**Outputs**
- `staging.stg_raw_events` – Deduplicated, parsed events table with 13 columns (event_id, user_id, session_id, event_type, page_url, referrer, device_type, browser, country, product_id, event_revenue, event_timestamp, _loaded_at)

**Key Transformations**
- JSON extraction of nested payload fields using `JSON_EXTRACT_PATH_TEXT()`
- Deduplication via `ROW_NUMBER()` partitioned by event_id, keeping most recent record
- Type casting: user_id and product_id to BIGINT; revenue to DECIMAL(12,2); event_time to TIMESTAMP
- Null handling: referrer defaults to 'direct', device_type to 'unknown', revenue to 0
- Lookback window: 3-day rolling ingestion with null event_id filtering

**Dependencies**
- Requires Redshift Spectrum access to `spectrum.raw_clickstream`
- Grants SELECT to `analytics_readers` group post-load
- Table distribution keyed on event_id; sorted by event_timestamp for query optimization

**Notes**
- Table is dropped and recreated on each run (full refresh pattern)
- `ANALYZE` command updates table statistics post-load for query planner optimization
- `_loaded_at` timestamp captures ingestion time for SLA tracking