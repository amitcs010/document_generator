# transforms/int_customer_sessions.sql

## Component Overview
- **Layer:** Transforms
- **Type:** Table (materialized)
- **Schedule:** Not specified in code; recommend daily or continuous based on event ingestion cadence
- **Owner:** Not specified in code; recommend Analytics Engineering team

---

## Purpose

This component reconstructs user sessions from raw clickstream events by detecting natural breaks in user activity (>30 minute gaps) and aggregating event-level data into session-level metrics. It serves as a foundational table for customer journey analysis, attribution modeling, and conversion funnel reporting. Downstream analytics, BI dashboards, and data science models depend on this sessionized view to understand user behavior patterns and campaign effectiveness.

---

## Inputs

- **staging.stg_raw_events** — Raw clickstream events containing user interactions (page views, clicks, purchases, etc.). This component requires event-level timestamps, user identifiers, event types, referrer information, and revenue data to reconstruct complete user sessions and compute session metrics.

---

## Outputs

- **transforms.int_customer_sessions** — Session-level aggregation table containing one row per user session with computed metrics (duration, event counts, revenue), attribution data (first/last touch referrer), and session classification. Consumed by downstream reporting tables, BI tools, and customer segmentation models.

---

## Key Business Logic

### 1. Session Boundary Detection
**What:** Events are grouped into sessions using a 30-minute inactivity threshold. Any gap >30 minutes between consecutive events (ordered by timestamp within a user) marks the start of a new session.

**Why:** 30 minutes is a standard industry convention for defining session boundaries in web analytics. It balances capturing related user intent (e.g., browsing → purchase) while separating distinct visits (e.g., morning browsing vs. evening purchase).

**Implementation:** The `session_boundaries` CTE uses a window function (`LAG()`) to detect gaps. A flag (`is_new_session`) is set to 1 when the gap exceeds 30 minutes or when it's the user's first event.

### 2. Session Sequencing
**What:** Sessions are assigned a sequential number (`session_seq`) per user, created by cumulatively summing the `is_new_session` flag.

**Why:** Provides a stable, deterministic session identifier that works even if the upstream `session_id` field is missing or malformed. Enables consistent grouping across the aggregation step.

### 3. Session-Level Aggregation
**What:** All events within a session are aggregated to compute:
- **Temporal metrics:** session start/end timestamps, duration in seconds
- **Event counts:** total events, distinct pages viewed, purchase/cart events
- **Revenue:** sum of event-level revenue (NVL handles nulls as $0)

**Why:** Reduces dimensionality from event-level to session-level, enabling efficient downstream analysis. Revenue aggregation supports conversion and AOV (average order value) calculations.

### 4. First/Last Touch Attribution
**What:** Using window functions with `FIRST_VALUE()` and `LAST_VALUE()`, the component captures:
- `first_touch_referrer` — the referrer source of the session's first event
- `last_touch_referrer` — the referrer source of the session's last event
- `device_type` — the device used for the session (assumed constant; uses first value)
- `country` — the user's country (assumed constant; uses first value)

**Why:** Enables multi-touch attribution analysis. First-touch identifies the initial marketing channel that acquired the user; last-touch identifies the channel most proximate to conversion. Device and country are session-level attributes used for segmentation.

**Assumption:** Device type and country are assumed constant within a session. If a user switches devices mid-session, only the first device is captured. This is a reasonable simplification for most use cases but may need refinement if cross-device sessions are common.

### 5. Session Outcome Classification
**What:** Sessions are classified into four mutually exclusive categories:
- `converted` — at least one purchase event
- `engaged` — no purchase but at least one add-to-cart event
- `browsing` — no purchase/cart but viewed >3 pages
- `bounced` — viewed ≤3 pages with no purchase/cart intent

**Why:** Provides a simple, actionable segmentation for funnel analysis and campaign performance evaluation. Helps identify high-intent sessions (converted/engaged) vs. exploratory sessions (browsing/bounced).

### 6. Session Length Bucketing
**What:** Sessions are classified by duration:
- `bounce` — <10 seconds
- `short` — 10 seconds to <2 minutes
- `medium` — 2 to <10 minutes
- `long` — ≥10 minutes

**Why:** Duration is a proxy for engagement quality. Very short sessions (<10s) likely indicate accidental clicks or bot traffic. Medium/long sessions correlate with higher intent and conversion likelihood. Enables cohort analysis by engagement depth.

---

## Column Descriptions

| Column | Data Type | Description | Example Values |
|--------|-----------|-------------|-----------------|
| **user_id** | VARCHAR | Unique identifier for the user. Primary key (with session_seq). | `user_12345`, `cust_abc789` |
| **session_id** | VARCHAR | Unique identifier for the session, sourced from raw events. May be null if upstream data is incomplete. | `sess_20240115_001`, `s_xyz123` |
| **session_seq** | BIGINT | Sequential session number per user, generated deterministically. Useful for ordering sessions chronologically. | `1`, `2`, `15` |
| **session_start** | TIMESTAMP | Timestamp of the first event in the session (UTC). | `2024-01-15 09:30:45` |
| **session_end** | TIMESTAMP | Timestamp of the last event in the session (UTC). | `2024-01-15 09:45:12` |
| **session_duration_sec** | BIGINT | Total session duration in seconds (session_end - session_start). | `927`, `45`, `3600` |
| **event_count** | BIGINT | Total number of events (rows) in the session. | `5`, `1`, `42` |
| **pages_viewed** | BIGINT | Count of distinct page URLs visited during the session. | `3`, `1`, `12` |
| **purchase_count** | BIGINT | Number of purchase events in the session. | `0`, `1`, `2` |
| **add_to_cart_count** | BIGINT | Number of add-to-cart events in the session. | `0`, `1`, `3` |
| **session_revenue** | DECIMAL | Total revenue attributed to the session (sum of event_revenue). Null events treated as $0. | `0.00`, `49.99`, `250.00` |
| **first_touch_referrer** | VARCHAR | Referrer source of the session's first event. Used for first-touch attribution. | `google`, `direct`, `facebook`, `email` |
| **last_touch_referrer** | VARCHAR | Referrer source of the session's last event. Used for last-touch attribution. | `google`, `direct`, `facebook`, `email` |
| **device_type** | VARCHAR | Device category of the session (assumed constant). | `mobile`, `desktop`, `tablet` |
| **country** | VARCHAR | Country of the user (assumed constant within session). | `US`, `GB`, `CA`, `DE` |
| **session_outcome** | VARCHAR | Classification of session intent/result. | `converted`, `engaged`, `browsing`, `bounced` |
| **session_length_bucket** | VARCHAR | Duration-based engagement classification. | `bounce`, `short`, `medium`, `long` |
| **_loaded_at** | TIMESTAMP | Timestamp when the row was loaded into the table (UTC). Used for SCD tracking and debugging. | `2024-01-15 12:00:00` |

---

## Data Quality & Edge Cases

### Null Handling
- **user_id:** Rows with null `user_id` are filtered out in the `session_boundaries` CTE (`WHERE e.user_id IS NOT NULL`). This prevents orphaned sessions and ensures all rows are attributable to a user.
- **event_revenue:** Null revenue values are treated as $0 using `NVL(event_revenue, 0)` in the `session_revenue` calculation. This assumes missing revenue is equivalent to zero revenue (e.g., non-transactional events like page views).
- **referrer, device_type, country:** If these fields are null in the raw events, they will propagate as nulls in the session-level columns. Downstream consumers should handle nulls (e.g., treat as "unknown" or "direct").

### Deduplication Strategy
- **No explicit deduplication:** The code assumes `staging.stg_raw_events` is already deduplicated at the event level. If duplicate events exist upstream, they will inflate `event_count`, `pages_viewed`, and revenue metrics.
- **Recommendation:** Add a deduplication step in the staging layer (e.g., using `ROW_NUMBER()` to keep only the first occurrence of duplicate event IDs).

### Key Assumptions
1. **Event timestamps are accurate and in UTC:** Session boundaries depend on correct timestamp ordering. Skewed or non-UTC timestamps will produce incorrect sessions.
2. **User IDs are stable:** The code assumes a user's ID does not change within the observation period. If user IDs are reassigned or merged, sessions may be incorrectly grouped.
3. **30-minute threshold is appropriate:** The hardcoded 30-minute gap may not suit all use cases (e.g., mobile apps with background activity, or high-frequency trading platforms). Consider parameterizing this value.
4. **Device and country are session-invariant:** The code assumes a user does not switch devices or countries mid-session. Cross-device sessions will only capture the first device.
5. **Event types are standardized:** The code filters on specific event types (`purchase`, `add_to_cart`). If upstream event types change or are misspelled, session classifications may be incorrect.

### Potential Failure Points
- **Missing session_id field:** If `staging.stg_raw_events` does not have a `session_id` column, the query will fail. The code should include a fallback (e.g., `COALESCE(session_id, CONCAT(user_id, '_', session_seq))`).
- **Timestamp data type mismatch:** If `event_timestamp` is stored as a string or date (not timestamp), the `DATEDIFF()` and window function ordering will fail or produce incorrect results.
- **Extremely large sessions:** If a single user has a very long session (e.g., a user who leaves their browser open for 24 hours), the session will be treated as one continuous session, potentially inflating duration and event counts.
- **Referrer/device/country changes mid-session:** The code captures only the first value. If these attributes change during a session, the change is lost.

---

## Performance Notes

### Partitioning & Distribution
- **DISTKEY(user_id):** Distributes rows across cluster nodes by user ID. This is optimal for queries that filter or join on `user_id` (e.g., "sessions for user X"). Ensures all events for a user are co-located, improving window function performance.
- **SORTKEY(session_start):** Sorts rows by session start timestamp within each node. Enables efficient range scans for time-based queries (e.g., "sessions in January 2024"). Secondary sort on `user_id` would improve performance further.

### Window Function Efficiency
- **LAG() in session_boundaries:** Partitioned by `user_id` and ordered by `event_timestamp`. This is efficient because the DISTKEY matches the partition key, avoiding cross-node shuffles.
- **FIRST_VALUE() and LAST_VALUE() in session_agg:** Partitioned by `user_id, session_seq` with `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING`. This frame specification requires scanning the entire partition, which is necessary but can be expensive for large sessions. Consider whether a simpler approach (e.g., `MIN()` with `CASE`) would be faster.

### Aggregation & Grouping
- **GROUP BY user_id, session_seq:** Groups events into sessions. This is a straightforward aggregation with no joins, so performance scales linearly with event volume.
- **COUNT(DISTINCT page_url):** Computes distinct page count. This is relatively efficient but can be slow if page URLs are very long or if there are many distinct pages per session.

### Full Table Scans
- The query reads all rows from `staging.stg_raw_events` without filtering by date. If this table is very large (billions of rows), consider adding a date filter (e.g., `WHERE event_date >= CURRENT_DATE - 30`) to limit the working set.

### Estimated Complexity
- **Time Complexity:** O(n log n) due to window function sorting and aggregation (where n = number of events).
- **Space Complexity:** O(n) for intermediate CTEs and the final table.
- **Recommendation:** For tables with >1 billion events, consider partitioning by date and processing incrementally (e.g., daily batches).

---

## Dependencies

### Upstream
- **staging.stg_raw_events** — Must be populated and deduplicated before this transform runs. Typically loaded via an ELT tool (e.g., Fivetran, Stitch) from a web analytics platform (e.g., Segment, Mixpanel) or application event logs.
- **Implicit:** Assumes `event_timestamp` is in UTC and `user_id` is stable and non-null.

### Downstream
- **reporting.fct_sessions** — Likely a fact table that joins `int_customer_sessions` with dimension tables (e.g., users, campaigns) for BI consumption.
- **reporting.dim_session_cohorts** — Possibly a dimension table that segments sessions by outcome, length, or referrer for cohort analysis.
- **ml_models.customer_lifetime_value** — Data science models may use session-level features (e.g., session_revenue, session_outcome) to predict CLV or churn.
- **dashboards.customer_journey** — BI dashboards likely query this table directly to visualize session funnels, attribution, and engagement metrics.

### External
- None explicitly referenced. However, the 30-minute session threshold and event type classifications (`purchase`, `add_to_cart`) are business rules that should be documented in a configuration system or wiki.

---

## Maintenance & Monitoring

### Recommended Alerts
- **Null user_id rate:** If >5% of raw events have null `user_id`, investigate data quality issues upstream.
- **Session duration outliers:** If max session duration exceeds 24 hours, investigate whether the 30-minute threshold is appropriate or if there are bot/test sessions.
- **Revenue anomalies:** If `session_revenue` distribution changes significantly, investigate upstream pricing or event tracking changes.
- **Table size growth:** Monitor row count and storage size. If growing faster than expected, investigate whether session boundaries are correct.

### Refresh Strategy
- **Frequency:** Recommend daily or continuous refresh, depending on event ingestion latency and reporting SLA.
- **Incremental vs. Full:** Currently a full table rebuild (DROP + CREATE). For large tables, consider incremental inserts (e.g., only process events from the last 24 hours).
- **Backfill:** If raw events are corrected retroactively, this table must be rebuilt to reflect corrections.

### Testing
- **Data validation:** Assert that `session_start <= session_end`, `event_count > 0`, and `session_revenue >= 0`.
- **Referential integrity:** Verify that all `user_id` values exist in a user dimension table (if one exists).
- **Regression testing:** Compare session counts and revenue totals to previous runs to detect unexpected changes.