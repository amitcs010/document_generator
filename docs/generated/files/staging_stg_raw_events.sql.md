# staging/stg_raw_events.sql

## Component Overview
- **Layer:** Staging
- **Type:** Table (materialized)
- **Schedule:** Not specified in code; infer from upstream `spectrum.raw_clickstream` refresh cadence
- **Owner:** Not specified in code; recommend documenting in deployment metadata

---

## Purpose

This component ingests raw clickstream events from the event bus and prepares them for downstream analytics consumption. It parses semi-structured JSON payloads into clean, typed columns; deduplicates events by `event_id` to handle replay scenarios; and applies basic data quality rules (null handling, type casting). The output serves as the single source of truth for all event-based analytics, feeding user behavior analysis, funnel reporting, and revenue attribution models.

---

## Inputs

| Source | Purpose | Notes |
|--------|---------|-------|
| **spectrum.raw_clickstream** | Raw clickstream events from the event bus in JSON format | Spectrum table suggests external data lake (S3/Parquet). Contains `event_id`, `event_time`, and nested `payload` JSON. Only events from the last 3 days are ingested. |

---

## Outputs

| Target | Contents | Downstream Consumers |
|--------|----------|----------------------|
| **staging.stg_raw_events** | Deduplicated, parsed, and typed clickstream events with 13 columns spanning user identity, session context, device/browser info, and transaction data. | `mart_user_sessions`, `mart_product_events`, `fct_revenue_transactions`, BI dashboards (via `analytics_readers` group), ad-hoc analytics queries. |

---

## Key Business Logic

### 1. **JSON Payload Parsing**
Raw events arrive as JSON in the `payload` column. The query extracts 10 nested fields using `JSON_EXTRACT_PATH_TEXT()`:
- User/session identifiers (`user_id`, `session_id`)
- Event metadata (`event_type`, `event_timestamp`)
- Navigation context (`page_url`, `referrer`)
- Device/browser fingerprinting (`device_type`, `browser`, `country`)
- Transaction data (`product_id`, `revenue`)

**Why:** Enables structured querying and joins downstream; avoids repeated JSON parsing in dependent queries.

### 2. **Deduplication by Event ID**
A `ROW_NUMBER()` window function partitions by `event_id` and orders by `event_time DESC`, keeping only the first row (`_row_num = 1`).

**Why:** Event bus systems often replay or re-emit events during failures or retries. Deduplication ensures each logical event appears exactly once in analytics. The DESC ordering on `event_time` prioritizes the most recent version if timestamps differ.

**Assumption:** `event_id` is globally unique and immutable; if the same event is re-emitted with a different `event_id`, this logic will not catch it.

### 3. **3-Day Lookback Window**
Only events from the last 3 days are included: `WHERE event_time >= DATEADD(day, -3, GETDATE())`.

**Why:** Balances freshness (captures recent events) with performance (avoids scanning entire history on each run). Assumes this table is refreshed daily or more frequently.

**Risk:** If the upstream table is not refreshed for >3 days, this table will become stale.

### 4. **Type Casting & Null Handling**
- `user_id` and `product_id` cast to `BIGINT` (assumes valid numeric IDs; invalid casts will error)
- `event_revenue` cast to `DECIMAL(12,2)` with `NVL(event_revenue, 0)` fallback (treats missing revenue as $0)
- `referrer` defaults to `'direct'` if null (assumes direct traffic when referrer is absent)
- `device_type` defaults to `'unknown'` if null (avoids null-related filtering issues downstream)

**Why:** Ensures consistent data types for joins and aggregations; prevents null-related bugs in downstream queries.

**Assumption:** Missing revenue means no transaction occurred (not that revenue is unknown). This may conflate "no purchase" with "purchase amount not captured."

### 5. **Timestamp Conversion**
`event_time` (presumed string or Unix timestamp) is converted to a Redshift `TIMESTAMP` type.

**Why:** Enables time-based filtering, window functions, and joins on time ranges downstream.

---

## Column Descriptions

| Column | Type | Description | Example Values |
|--------|------|-------------|-----------------|
| **event_id** | VARCHAR | Unique identifier for the event; used for deduplication. | `evt_abc123xyz`, `evt_def456uvw` |
| **user_id** | BIGINT | Unique identifier for the user who triggered the event. | `12345`, `67890` |
| **session_id** | VARCHAR | Unique identifier for the user's session; groups events within a visit. | `sess_abc123`, `sess_def456` |
| **event_type** | VARCHAR | Category of the event (e.g., page view, click, purchase). | `page_view`, `add_to_cart`, `purchase`, `search` |
| **page_url** | VARCHAR | Full URL of the page where the event occurred. | `https://example.com/products/shoes`, `https://example.com/checkout` |
| **referrer** | VARCHAR | HTTP referrer (source of traffic); defaults to `'direct'` if null. | `https://google.com`, `direct`, `https://facebook.com` |
| **device_type** | VARCHAR | Device category; defaults to `'unknown'` if null. | `mobile`, `desktop`, `tablet`, `unknown` |
| **browser** | VARCHAR | Browser name/version. | `Chrome 120`, `Safari 17`, `Firefox 121` |
| **country** | VARCHAR | Country code or name derived from IP geolocation. | `US`, `GB`, `DE`, `JP` |
| **product_id** | BIGINT | Unique identifier for the product involved in the event (if applicable). | `5001`, `5002`, NULL (for non-product events) |
| **event_revenue** | DECIMAL(12,2) | Revenue (in USD) associated with the event; defaults to `0` if null. | `29.99`, `0.00`, `149.50` |
| **event_timestamp** | TIMESTAMP | Timestamp when the event occurred (server-side). | `2024-01-15 14:32:45.123`, `2024-01-15 09:00:00.000` |
| **_loaded_at** | TIMESTAMP | Timestamp when the row was loaded into the staging table (for SLA tracking). | `2024-01-15 15:00:00.000` |

---

## Data Quality & Edge Cases

### Null Handling
| Column | Null Behavior | Risk |
|--------|---------------|------|
| `user_id` | Cast to BIGINT; invalid strings will cause query failure | If upstream sends non-numeric user IDs, the entire load fails. Recommend pre-validation or TRY_CAST. |
| `product_id` | Cast to BIGINT; NULL values allowed | Non-product events (e.g., page views) will have NULL; this is expected. |
| `event_revenue` | Defaults to `0` via `NVL()` | Conflates "no revenue" with "revenue not captured." Revenue attribution may be understated if capture is inconsistent. |
| `referrer` | Defaults to `'direct'` via `NVL()` | Direct traffic may be overstated if referrer capture is unreliable. |
| `device_type` | Defaults to `'unknown'` via `NVL()` | Device segmentation will include an `'unknown'` bucket; monitor its size. |
| `browser` | No default; NULL values allowed | Browser analysis will exclude events with missing browser data. |
| `country` | No default; NULL values allowed | Geographic analysis will exclude events with missing country data. |

### Deduplication Strategy
- **Method:** `ROW_NUMBER() OVER (PARTITION BY event_id ORDER BY event_time DESC)`
- **Assumption:** If the same `event_id` appears multiple times, the most recent `event_time` is the authoritative version.
- **Edge Case:** If an event is corrected (e.g., revenue updated) but retains the same `event_id`, only the latest version is kept. Earlier versions are discarded.
- **Risk:** If the event bus sends the same `event_id` with different `event_time` values due to clock skew, the "most recent" may not be the "most correct."

### Data Assumptions
1. **event_id is globally unique:** No two distinct logical events share the same `event_id`.
2. **event_time is monotonic (mostly):** Events are timestamped in order; minor clock skew is acceptable.
3. **JSON payload structure is consistent:** All events have the same nested field names; missing fields are null, not absent.
4. **Revenue is in USD:** No currency conversion is performed.
5. **3-day lookback is sufficient:** Upstream data is refreshed at least every 3 days.

### Potential Breakage Points
- **Upstream schema change:** If `spectrum.raw_clickstream` renames or removes the `payload` column, or if JSON field names change, `JSON_EXTRACT_PATH_TEXT()` will return NULLs or fail.
- **Invalid numeric data:** If `user_id`, `product_id`, or `event_revenue` contain non-numeric strings, the CAST operations will fail.
- **Timestamp format change:** If `event_time` format changes (e.g., from ISO 8601 to Unix milliseconds), `CONVERT(TIMESTAMP, event_time)` may fail or produce incorrect results.
- **Event ID collisions:** If the upstream system generates duplicate `event_id` values for distinct events, deduplication will silently drop valid events.

---

## Performance Notes

### Distribution & Sort Keys
| Key | Strategy | Rationale |
|-----|----------|-----------|
| **DISTKEY(event_id)** | Hash distribution on `event_id` | Ensures events with the same ID co-locate on the same node, optimizing the deduplication window function. Enables efficient joins downstream on `event_id`. |
| **SORTKEY(event_timestamp)** | Sort on `event_timestamp` | Optimizes time-range queries (e.g., "events in the last 7 days"). Improves compression and scan performance for time-based filters. |

### Join Strategy
- **No explicit joins in this query.** The deduplication is performed via a window function within a single table scan.
- **Window function cost:** `ROW_NUMBER() OVER (PARTITION BY event_id ORDER BY event_time DESC)` requires a full table scan and sort within each partition. For large event volumes (millions of rows), this can be expensive.

### Expensive Operations
1. **JSON parsing:** `JSON_EXTRACT_PATH_TEXT()` is called 10 times per row. For millions of rows, this is CPU-intensive. Consider pre-parsing in the source system if possible.
2. **Type casting:** Multiple CAST operations (BIGINT, DECIMAL, TIMESTAMP) add overhead. Invalid data will cause query failure.
3. **Window function:** The `ROW_NUMBER()` operation requires sorting within each `event_id` partition. If `event_id` cardinality is high (millions of unique IDs), this is efficient; if low (few unique IDs), partitions are large and sorting is expensive.

### Full Table Scans
- The query scans all of `spectrum.raw_clickstream` (filtered to 3 days). If the source table is not partitioned on `event_time`, this is a full table scan. Recommend confirming that Spectrum table is partitioned on `event_time` to enable partition pruning.

### Materialization Strategy
- **DROP TABLE IF EXISTS + CREATE TABLE AS:** This is a full refresh. On each run, the entire table is rebuilt. For large event volumes, this can be slow and resource-intensive.
- **Alternative:** Consider incremental loading (INSERT only new events) if the 3-day window is stable and deduplication is not needed for historical data.

### Estimated Row Count & Storage
- **Assumption:** ~1M events per day → ~3M rows in this table.
- **Storage:** 13 columns × 3M rows × ~200 bytes/row ≈ 600 MB (rough estimate; actual depends on compression).
- **Load time:** ~30–60 seconds on a typical Redshift cluster (depends on cluster size and concurrency).

---

## Dependencies

### Upstream
| Component | Type | Criticality | Notes |
|-----------|------|-------------|-------|
| **spectrum.raw_clickstream** | External table (S3/Parquet) | **CRITICAL** | Must be refreshed at least every 3 days. If unavailable or delayed, this table will not refresh. No fallback. |

### Downstream
| Component | Type | Dependency | Notes |
|-----------|------|-----------|-------|
| **mart_user_sessions** | Mart table | Joins on `event_id`, `user_id`, `session_id` | Aggregates events into session-level metrics. |
| **mart_product_events** | Mart table | Joins on `product_id`, `event_type` | Filters for product-related events; computes product-level KPIs. |
| **fct_revenue_transactions** | Fact table | Filters on `event_type = 'purchase'` and uses `event_revenue` | Revenue attribution; must handle NULL `product_id` gracefully. |
| **BI dashboards** | Dashboards (Tableau/Looker) | Direct queries via `analytics_readers` group | Real-time event exploration; filters on `event_timestamp`, `country`, `device_type`. |
| **Ad-hoc analytics** | Queries | Direct access via `analytics_readers` group | Data scientists and analysts query for exploratory analysis. |

### External
| System | Purpose | Notes |
|--------|---------|-------|
| **Event bus** | Source of raw clickstream data | Assumed to be reliable; no SLA specified. |
| **IP geolocation service** | Populates `country` field | Assumed to be performed upstream; this query does not perform geolocation. |

---

## Maintenance & Monitoring

### Recommended Alerts
- **Load time exceeds 2 minutes:** Investigate performance degradation or upstream delays.
- **Row count drops >20% day-over-day:** Investigate data quality issues or upstream outages.
- **NULL rate for `user_id` or `event_id` exceeds 1%:** Investigate upstream schema changes or data quality issues.
- **Deduplication removes >5% of rows:** Investigate event replay or ID collision issues.

### Recommended Tests
- **Uniqueness:** Verify `event_id` is unique in the output (no duplicates after deduplication).
- **Referential integrity:** Spot-check that `user_id` and `product_id` values exist in upstream master tables.
- **Timestamp ordering:** Verify `event_timestamp` is reasonable (not in the future, not before 2020).
- **Revenue bounds:** Verify `event_revenue` is non-negative and within expected range (e.g., < $10,000).

### Refresh Cadence
- **Recommended:** Daily (e.g., 02:00 UTC) to capture events from the previous day.
- **Assumption:** Upstream `spectrum.raw_clickstream` is refreshed at least daily.