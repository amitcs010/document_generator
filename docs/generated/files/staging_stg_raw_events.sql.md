# staging/stg_raw_events.sql

## Component Overview
- **Layer:** Staging
- **Type:** Table (materialized)
- **Schedule:** Not specified in code; infer from upstream `spectrum.raw_clickstream` refresh cadence
- **Owner:** Not specified in code; recommend documenting in team wiki

---

## Purpose

This component ingests raw clickstream events from the event bus and prepares them for downstream analytics consumption. It parses semi-structured JSON payloads into clean, typed columns and removes duplicate events that may arrive multiple times due to event bus retry logic. The output serves as the single source of truth for all user interaction events and is consumed by fact tables, user journey analyses, and real-time dashboards.

---

## Inputs

| Source | Purpose | Notes |
|--------|---------|-------|
| **spectrum.raw_clickstream** | Raw event stream from event bus containing JSON-encoded clickstream data | Spectrum table suggests data may be stored in S3; 3-day lookback window applied to reduce scan volume |

---

## Outputs

| Target | Contents | Downstream Consumers |
|--------|----------|----------------------|
| **staging.stg_raw_events** | Deduplicated, parsed clickstream events with typed columns (user_id, session_id, event_type, revenue, etc.) | Fact tables (e.g., `fct_events`), user dimension tables, session analytics, attribution models, revenue reporting |

---

## Key Business Logic

### 1. **JSON Payload Parsing**
Raw events arrive as JSON in a `payload` column. The code extracts 11 business-relevant fields using `JSON_EXTRACT_PATH_TEXT()`:
- User/session identifiers (`user_id`, `session_id`)
- Event metadata (`event_type`, `event_timestamp`)
- Page context (`page_url`, `referrer`)
- Device/browser info (`device_type`, `browser`, `country`)
- Commerce data (`product_id`, `revenue`)

**Why:** Enables downstream queries to filter, aggregate, and join on structured columns rather than parsing JSON repeatedly.

### 2. **Deduplication by Event ID**
Events are deduplicated using a `ROW_NUMBER()` window function partitioned by `event_id` and ordered by `event_time DESC`:
```sql
ROW_NUMBER() OVER (PARTITION BY event_id ORDER BY event_time DESC) AS _row_num
```
Only rows where `_row_num = 1` are retained (most recent arrival).

**Why:** The event bus may retry failed deliveries, causing the same event to appear multiple times. Keeping the most recent record ensures we capture any late-arriving corrections while eliminating duplicates.

### 3. **Temporal Filtering**
Only events from the last 3 days are ingested:
```sql
WHERE event_time >= DATEADD(day, -3, GETDATE())
```

**Why:** Reduces scan volume on Spectrum (S3) and focuses on recent, actionable data. Assumes historical events are already loaded; adjust if backfill is needed.

### 4. **Type Casting & Coercion**
- `user_id` and `product_id` cast to `BIGINT` (from JSON string)
- `event_revenue` cast to `DECIMAL(12,2)` for financial accuracy
- `event_timestamp` converted from string to `TIMESTAMP`

**Why:** Ensures numeric precision for joins and aggregations; prevents silent type mismatches downstream.

### 5. **Null Handling with Business Defaults**
- `referrer` defaults to `'direct'` if null (user came directly, not via referral)
- `device_type` defaults to `'unknown'` if not captured
- `event_revenue` defaults to `0` if missing (non-transactional events)

**Why:** Prevents null propagation in downstream aggregations and provides sensible defaults aligned with business interpretation.

### 6. **Null Validation on Keys**
```sql
WHERE event_id IS NOT NULL
```

**Why:** `event_id` is the deduplication key; null values would break the window function and create ambiguous records.

---

## Column Descriptions

| Column | Type | Description | Example Values |
|--------|------|-------------|-----------------|
| **event_id** | VARCHAR | Unique identifier for the event; used for deduplication | `evt_a1b2c3d4e5f6` |
| **user_id** | BIGINT | Internal user identifier; links to user dimension | `12345`, `67890` |
| **session_id** | VARCHAR | Session identifier; groups events within a user visit | `sess_xyz789` |
| **event_type** | VARCHAR | Classification of user action | `page_view`, `add_to_cart`, `purchase`, `search` |
| **page_url** | VARCHAR | Full URL of the page where event occurred | `https://example.com/products/shoes?color=red` |
| **referrer** | VARCHAR | HTTP referrer or `'direct'` if not provided | `https://google.com`, `direct`, `https://facebook.com` |
| **device_type** | VARCHAR | Device category or `'unknown'` if not captured | `mobile`, `desktop`, `tablet`, `unknown` |
| **browser** | VARCHAR | Browser name and version | `Chrome 120.0`, `Safari 17.1`, `Firefox 121.0` |
| **country** | VARCHAR | ISO country code or country name | `US`, `GB`, `DE`, `JP` |
| **product_id** | BIGINT | Product identifier; links to product dimension | `5001`, `9999` |
| **event_revenue** | DECIMAL(12,2) | Revenue attributed to event (0 if non-transactional) | `29.99`, `0.00`, `149.50` |
| **event_timestamp** | TIMESTAMP | When the event occurred (server time) | `2024-01-15 14:32:45.123` |
| **_loaded_at** | TIMESTAMP | When the record was loaded into staging (ETL timestamp) | `2024-01-15 15:00:00.000` |

---

## Data Quality & Edge Cases

### Null Handling Strategy
| Column | Null Behavior | Rationale |
|--------|---------------|-----------|
| `event_id` | **Rejected** (filtered out) | Cannot deduplicate without it |
| `user_id` | **Allowed** (cast to BIGINT, may fail if non-numeric) | Anonymous events possible; risk of cast failure |
| `referrer` | **Replaced with `'direct'`** | Business default; assumes direct traffic if missing |
| `device_type` | **Replaced with `'unknown'`** | Prevents null in downstream GROUP BY queries |
| `event_revenue` | **Replaced with `0`** | Non-transactional events have no revenue |
| `browser`, `country` | **Allowed** | May be null for certain event types or privacy-restricted users |

### Deduplication Assumptions
- **Assumption:** If the same `event_id` appears multiple times, the most recent arrival (by `event_time`) is the authoritative version.
- **Risk:** If the event bus reorders messages (out-of-order delivery), the "most recent" may not be the final state. Consider adding a `_version` or `_checksum` column if late-arriving corrections are common.

### Temporal Window Assumptions
- **Assumption:** All events older than 3 days have already been loaded into a historical table.
- **Risk:** If backfill is needed or if the upstream source has a longer retention window, events may be missed. Adjust `DATEADD(day, -3, ...)` or implement a high-water mark pattern.

### Type Casting Risks
- **Risk:** If `user_id` or `product_id` contain non-numeric strings (e.g., `"N/A"`, `"unknown"`), the `CAST` to `BIGINT` will fail and the entire load will abort.
- **Mitigation:** Consider wrapping casts in `TRY_CAST()` or adding validation upstream.

### JSON Parsing Fragility
- **Risk:** If the JSON schema changes (new fields added, existing fields removed, or renamed), this code will silently produce nulls for missing fields.
- **Mitigation:** Add schema validation or use a schema registry (e.g., Confluent Schema Registry) to detect breaking changes.

---

## Performance Notes

### Distribution & Sort Keys
```sql
DISTSTYLE KEY
DISTKEY(event_id)
SORTKEY(event_timestamp)
```

| Key | Strategy | Rationale | Trade-offs |
|-----|----------|-----------|-----------|
| **DISTKEY(event_id)** | Distribute rows by event_id | Ensures deduplication window function runs locally on each node; reduces network shuffle | If event_ids are skewed (some ids much more frequent), may cause data skew and uneven node utilization |
| **SORTKEY(event_timestamp)** | Sort by event_timestamp | Enables efficient range scans for time-based queries (e.g., "events in last 7 days"); improves compression | Secondary sort key not specified; consider adding `event_type` or `user_id` for multi-column range queries |

### Expensive Operations
| Operation | Cost | Mitigation |
|-----------|------|-----------|
| **Spectrum scan** (`spectrum.raw_clickstream`) | High (S3 I/O) | 3-day lookback window reduces scan volume; consider partitioning S3 data by date |
| **ROW_NUMBER() window function** | Medium (sorts within partition) | Partitioned by `event_id` (distribution key), so runs locally; acceptable for typical event volumes |
| **JSON_EXTRACT_PATH_TEXT()** | Low-Medium (per-row parsing) | Parsing happens once during ingestion; downstream queries use typed columns |
| **CAST operations** | Low (per-row type conversion) | Minimal overhead; consider pre-casting in source if volume is very high |

### Recommended Optimizations
1. **Add date partition to Spectrum source:** If `spectrum.raw_clickstream` is partitioned by date in S3, explicitly filter on partition columns to avoid full table scan.
2. **Consider incremental load:** Instead of re-processing 3 days of data every run, implement a high-water mark (e.g., track max `event_time` loaded) and only process new events.
3. **Monitor for data skew:** If certain `event_id` values are extremely frequent, consider alternative distribution keys (e.g., `DISTKEY(user_id)` if user-based queries are more common).

---

## Dependencies

### Upstream
| Component | Type | Criticality | Notes |
|-----------|------|-------------|-------|
| **spectrum.raw_clickstream** | External table (S3) | **Critical** | Must be available and contain valid JSON payloads; no SLA specified |
| **Event bus** | External system | **Critical** | Source of raw events; retry logic may cause duplicates (handled by deduplication) |

### Downstream
| Component | Type | Usage | Criticality |
|-----------|------|-------|-------------|
| **fct_events** (assumed) | Fact table | Consumes deduplicated events for dimensional analysis | **High** |
| **dim_user** (assumed) | Dimension table | May join on `user_id` for user attributes | **High** |
| **dim_product** (assumed) | Dimension table | May join on `product_id` for product attributes | **Medium** |
| **Real-time dashboards** (assumed) | BI tools | May query directly for recent event trends | **Medium** |
| **Attribution models** (assumed) | Analytics | Uses event sequence and timestamps for multi-touch attribution | **High** |
| **analytics_readers** group | IAM role | Granted SELECT permission for read access | **Medium** |

### External Dependencies
| Dependency | Type | Purpose | Risk |
|------------|------|---------|------|
| **Redshift Spectrum** | AWS service | Query S3 data without copying | If S3 bucket permissions change or S3 data format changes, queries fail |
| **JSON schema** (implicit) | Data contract | Defines which fields are extracted from payload | If upstream event schema changes, silent nulls or failures occur |
| **System clock (GETDATE())** | System function | Used for `_loaded_at` and temporal filtering | If server clock drifts, temporal filtering may be inaccurate |

### Execution Dependencies
- **Must run after:** Event bus has delivered events to `spectrum.raw_clickstream`
- **Must complete before:** Any downstream fact/dimension tables that depend on this staging table
- **Frequency:** Recommend daily or more frequent (e.g., hourly) based on downstream SLA; not specified in code

---

## Maintenance & Monitoring Recommendations

### Alerts to Configure
1. **Load failure:** If `spectrum.raw_clickstream` is unavailable or JSON parsing fails
2. **Data freshness:** If `_loaded_at` is older than expected (e.g., > 2 hours)
3. **Duplicate rate:** If deduplication removes > X% of raw events (may indicate upstream issue)
4. **Null rate:** If any column has > Y% nulls (may indicate schema change or data quality issue)
5. **Data skew:** If any `event_id` represents > Z% of total rows (may cause performance degradation)

### Documentation Gaps to Address
- **Owner:** Who maintains this code?
- **Schedule:** How often does this run? (hourly, daily, on-demand?)
- **SLA:** What is the acceptable latency from event occurrence to availability in this table?
- **Backfill procedure:** How are historical events loaded if the 3-day window is insufficient?
- **Schema change process:** How are breaking changes to the JSON payload communicated and handled?