# staging/stg_raw_events.sql

## Component Overview
- **Layer:** Staging
- **Type:** Table (materialized)
- **Schedule:** Not specified in code (infer from orchestration layer)
- **Owner:** Not specified in code (infer from team documentation)

---

## Purpose

This component ingests raw clickstream events from the event bus and transforms them into a clean, deduplicated staging table ready for downstream analytics. It parses semi-structured JSON payloads into typed columns, applies business-critical deduplication logic, and enforces data quality standards (null handling, type casting). The output serves as the single source of truth for all event-based analytics, powering user behavior analysis, conversion funnels, and product metrics.

---

## Inputs

| Source | Purpose | Notes |
|--------|---------|-------|
| **spectrum.raw_clickstream** | Raw clickstream events from the event bus in JSON format | External table (Redshift Spectrum); contains `event_id`, `event_time`, and `payload` (JSON blob). Only events from the last 3 days are processed. |

---

## Outputs

| Target | Contents | Downstream Consumers |
|--------|----------|----------------------|
| **staging.stg_raw_events** | Deduplicated, typed clickstream events with 13 columns spanning user identity, session context, device/browser info, and transaction data. One row per unique `event_id`. | Analytics dashboards, conversion funnel models, user segmentation pipelines, product analytics, revenue attribution workflows. |

---

## Key Business Logic

### 1. **JSON Payload Parsing**
Raw events arrive as JSON blobs in the `payload` column. The transformation extracts 10 key fields using `JSON_EXTRACT_PATH_TEXT()`:
- User identity (`user_id`, `session_id`)
- Event classification (`event_type`)
- Navigation context (`page_url`, `referrer`)
- Device/browser fingerprinting (`device_type`, `browser`, `country`)
- Transaction data (`product_id`, `revenue`)

**Why:** Enables structured querying and joins against user/product dimensions downstream.

### 2. **Deduplication by Event ID**
A `ROW_NUMBER()` window function partitions by `event_id` and orders by `event_time DESC`, keeping only the most recent occurrence (`_row_num = 1`).

**Why:** Event bus may deliver duplicate events due to retries, network failures, or multi-region replication. Deduplication ensures metrics are not artificially inflated and maintains referential integrity for downstream joins.

**Assumption:** Later timestamps represent corrected/complete versions of earlier duplicates (e.g., enriched events).

### 3. **3-Day Lookback Window**
Only events from the last 3 days are ingested (`WHERE event_time >= DATEADD(day, -3, GETDATE())`).

**Why:** Balances freshness (near-real-time analytics) with storage efficiency. Assumes historical events are already materialized in a data warehouse layer and this staging table is for incremental/recent data only.

### 4. **Type Casting & Null Handling**
- `user_id` and `product_id` cast to `BIGINT` (assumes valid numeric IDs or nulls)
- `event_revenue` cast to `DECIMAL(12,2)` with `NVL(event_revenue, 0)` default (treats missing revenue as $0)
- `referrer` defaults to `'direct'` if null (standard web analytics convention)
- `device_type` defaults to `'unknown'` if null (prevents null-related query errors)

**Why:** Ensures consistent data types for joins and aggregations; prevents null-related query failures in downstream models.

### 5. **Timestamp Normalization**
`event_time` (string/timestamp from JSON) is converted to a Redshift `TIMESTAMP` type and renamed to `event_timestamp`.

**Why:** Enables time-based filtering, window functions, and time-series aggregations downstream.

### 6. **Load Tracking**
`_loaded_at` captures the exact time the row was inserted (`GETDATE()`), enabling data freshness monitoring and incremental load detection.

**Why:** Supports SLA monitoring, debugging of stale data, and incremental refresh logic in downstream pipelines.

---

## Column Descriptions

| Column | Type | Description | Example Values |
|--------|------|-------------|-----------------|
| **event_id** | VARCHAR | Unique identifier for the event; used as deduplication key. | `evt_12345abc`, `evt_67890def` |
| **user_id** | BIGINT | Unique identifier for the user who triggered the event. | `1001`, `5432109` |
| **session_id** | VARCHAR | Session identifier; groups events from a single user visit. | `sess_abc123`, `sess_xyz789` |
| **event_type** | VARCHAR | Classification of the event (e.g., page view, click, purchase). | `page_view`, `add_to_cart`, `purchase`, `search` |
| **page_url** | VARCHAR | Full URL of the page where the event occurred. | `https://example.com/products/shoes`, `https://example.com/checkout` |
| **referrer** | VARCHAR | HTTP referrer (source of traffic); defaults to `'direct'` if null. | `https://google.com`, `direct`, `https://facebook.com` |
| **device_type** | VARCHAR | Device category; defaults to `'unknown'` if null. | `mobile`, `desktop`, `tablet`, `unknown` |
| **browser** | VARCHAR | Browser name/version. | `Chrome 120`, `Safari 17`, `Firefox 121` |
| **country** | VARCHAR | Geographic location (ISO country code or name). | `US`, `GB`, `DE`, `JP` |
| **product_id** | BIGINT | Product identifier associated with the event (null if not applicable). | `5001`, `9999`, NULL |
| **event_revenue** | DECIMAL(12,2) | Revenue attributed to the event; defaults to `0` if null. | `29.99`, `0.00`, `149.50` |
| **event_timestamp** | TIMESTAMP | Exact time the event occurred (UTC). | `2024-01-15 14:32:45.123`, `2024-01-15 09:00:00.000` |
| **_loaded_at** | TIMESTAMP | Time the row was inserted into the staging table (UTC). | `2024-01-15 15:00:00.000` |

---

## Data Quality & Edge Cases

### Null Handling Strategy
| Column | Null Behavior | Rationale |
|--------|---------------|-----------|
| `event_id` | Filtered out (`WHERE event_id IS NOT NULL`) | Event ID is the deduplication key; nulls are invalid. |
| `user_id` | Cast to BIGINT; nulls preserved | Anonymous events are valid; downstream queries must handle nulls. |
| `referrer` | Replaced with `'direct'` | Standard web analytics convention; avoids null-related query errors. |
| `device_type` | Replaced with `'unknown'` | Prevents null-related aggregation issues; enables complete device breakdowns. |
| `event_revenue` | Replaced with `0` | Non-transactional events have no revenue; zero is semantically correct. |
| `product_id` | Nulls preserved | Not all events are product-related (e.g., page views); nulls are valid. |

### Deduplication Assumptions
- **Assumption 1:** If multiple events share the same `event_id`, the most recent (by `event_time DESC`) is the authoritative version.
  - **Risk:** If the event bus sends corrected/enriched events *before* original events, this logic may discard the enriched version.
  - **Mitigation:** Validate with event bus team that timestamps always increase monotonically for corrections.

- **Assumption 2:** Deduplication is scoped to `event_id` only; no cross-event deduplication (e.g., detecting duplicate sessions).
  - **Risk:** Session-level duplicates (e.g., two identical page views 1 second apart) are not detected.
  - **Mitigation:** If needed, add downstream deduplication logic in mart layer.

### Data Freshness & Lookback Window
- **Assumption:** The 3-day lookback is sufficient for all downstream use cases.
  - **Risk:** If a downstream model requires events older than 3 days, they will be missing.
  - **Mitigation:** Document the 3-day SLA; if longer history is needed, create a separate historical archive table.

### Type Casting Risks
- **Risk:** `CAST(user_id AS BIGINT)` will fail if `user_id` contains non-numeric values (e.g., `"user_abc"`).
  - **Mitigation:** Add validation in upstream data quality checks; consider `TRY_CAST()` if available.

- **Risk:** `CAST(JSON_EXTRACT_PATH_TEXT(payload, 'revenue') AS DECIMAL(12,2))` will fail on malformed JSON or non-numeric revenue values.
  - **Mitigation:** Use `TRY_CAST()` or add error handling; log failures to a dead-letter queue.

### Missing Columns
- **Risk:** If the event bus adds new fields to the JSON payload, they are not captured (e.g., `utm_source`, `utm_medium`).
  - **Mitigation:** Establish a process for updating the JSON extraction logic; consider a generic JSON column for future extensibility.

---

## Performance Notes

### Distribution & Sort Keys
| Key | Strategy | Rationale |
|-----|----------|-----------|
| **DISTKEY(event_id)** | Hash distribution on `event_id` | Ensures all duplicate events (same `event_id`) land on the same node, enabling efficient deduplication in the window function. Reduces network shuffles during the `ROW_NUMBER()` operation. |
| **SORTKEY(event_timestamp)** | Sort on `event_timestamp` | Enables efficient time-range scans for downstream queries (e.g., "events in the last 24 hours"). Improves performance of time-series aggregations. |

### Expensive Operations
| Operation | Cost | Mitigation |
|-----------|------|-----------|
| **JSON_EXTRACT_PATH_TEXT()** (10 calls per row) | Medium | JSON parsing is CPU-intensive. If payload is very large (>10KB), consider pre-parsing upstream. |
| **ROW_NUMBER() OVER (PARTITION BY event_id ...)** | Medium | Window function requires sorting within each partition. With high cardinality `event_id`, this can be expensive. Mitigated by `DISTKEY(event_id)` (local sort). |
| **CAST() operations** (3 casts per row) | Low | Type casting is fast; risk is invalid data causing failures (see Data Quality section). |
| **DATEADD() in WHERE clause** | Low | Predicate is evaluated once; no per-row cost. |

### Full Table Scans
- **Spectrum.raw_clickstream:** The entire external table is scanned (no partition pruning on Spectrum in this query).
  - **Risk:** If raw_clickstream is very large, this can be slow.
  - **Mitigation:** Ensure raw_clickstream is partitioned by date in S3; add partition pruning logic if Spectrum supports it.

### Table Size Estimation
- **Assumption:** ~1M events per day (typical for mid-size SaaS).
- **Estimated size:** 3 days × 1M events × ~500 bytes/row ≈ 1.5 GB.
- **Recommendation:** Monitor table size; if it exceeds 10 GB, consider archiving older data or increasing the 3-day window.

---

## Dependencies

### Upstream
| Component | Type | Purpose | SLA |
|-----------|------|---------|-----|
| **spectrum.raw_clickstream** | External table (S3) | Raw event data from event bus | Events should arrive within 5 minutes of occurrence |
| **Event bus** | External system | Produces clickstream events | Must maintain event ordering and deduplication guarantees |

### Downstream
| Component | Type | Purpose | Dependency Type |
|-----------|------|---------|-----------------|
| **mart.fct_events** | Fact table | Conformed events for analytics | Direct consumer; depends on `stg_raw_events` for daily refresh |
| **mart.dim_users** | Dimension table | User profiles | Consumes `user_id` from `stg_raw_events` for user identification |
| **mart.dim_sessions** | Dimension table | Session metadata | Consumes `session_id` and `event_timestamp` for session reconstruction |
| **Analytics dashboards** | BI tools (Tableau, Looker) | User behavior, conversion funnels, revenue metrics | Consume `mart.fct_events` (which depends on this table) |
| **Conversion funnel model** | dbt model | Tracks user progression through purchase flow | Depends on `event_type` and `event_timestamp` |
| **Product analytics pipeline** | Python/dbt | Computes product-level KPIs | Depends on `product_id` and `event_revenue` |

### External Dependencies
| System | Purpose | Notes |
|--------|---------|-------|
| **Redshift Spectrum** | Query S3 data | Must have valid IAM credentials and S3 bucket access |
| **S3 (raw_clickstream location)** | Event data storage | Bucket must be readable by Redshift cluster |
| **Redshift cluster** | Compute & storage | Must have sufficient disk space and compute capacity |

### Permissions
- **Read:** `spectrum.raw_clickstream` (via Spectrum IAM role)
- **Write:** `staging.stg_raw_events` (via Redshift role)
- **Grant:** `SELECT ON staging.stg_raw_events TO GROUP analytics_readers` (enables downstream consumers to query this table)

---

## Maintenance & Monitoring

### Recommended Alerts
- **Table size growth:** Alert if `stg_raw_events` exceeds 10 GB (indicates potential data quality issue or lookback window misconfiguration).
- **Freshness:** Alert if `MAX(_loaded_at)` is older than 1 hour (indicates pipeline failure).
- **Deduplication rate:** Monitor `COUNT(DISTINCT event_id)` vs. raw row count; if dedup rate drops below 95%, investigate event bus for anomalies.
- **Null rates:** Track null percentages for `user_id`, `product_id`, `event_revenue`; alert if they exceed historical baselines.

### Refresh Strategy
- **Frequency:** Daily (inferred from 3-day lookback; adjust based on orchestration schedule).
- **Incremental vs. Full:** Currently full refresh (drops and recreates table). Consider incremental upsert if table grows beyond 50 GB.
- **Backfill:** If historical data is needed, create a separate backfill job with extended lookback window.

---

## Related Documentation
- Event bus schema & payload specification (link to event team docs)
- Redshift Spectrum setup guide (link to infra docs)
- Downstream mart layer documentation (`mart.fct_events`, `mart.dim_users`)
- Data quality SLA & monitoring dashboard (link to data ops)