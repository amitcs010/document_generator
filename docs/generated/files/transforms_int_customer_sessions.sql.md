# transforms/int_customer_sessions.sql

## Component Overview
- **Layer:** Transforms
- **Type:** Table (materialized)
- **Schedule:** Not specified in code; recommend daily or continuous based on event ingestion cadence
- **Owner:** Not specified in code; recommend Analytics Engineering team

---

## Purpose

This component reconstructs user sessions from raw clickstream events by detecting natural breaks in user activity (>30 minute gaps) and aggregating event-level data into session-level metrics. It serves as a foundational table for customer journey analysis, attribution modeling, and conversion funnel reporting. Downstream analytics, BI dashboards, and data science models depend on this sessionized view to answer questions like "How many users converted in their first session?" or "What's the average session duration by device type?"

---

## Inputs

- **staging.stg_raw_events** — Raw clickstream events with user identifiers, timestamps, event types (purchase, add_to_cart, page_view), referrer information, device/geo attributes, and optional revenue values. This component requires clean, deduplicated events with non-null user_id and event_timestamp to function correctly.

---

## Outputs

- **transforms.int_customer_sessions** — Session-level aggregation table containing one row per user session, with metrics including session duration, event counts, conversion indicators, attribution touchpoints, and session outcome classifications. Consumed by downstream BI tools, customer segmentation models, and attribution analysis workflows.

---

## Key Business Logic

### 1. Session Boundary Detection
**Logic:** A new session begins when either (a) a user's event gap exceeds 30 minutes, or (b) it is the user's first event ever.

**Why:** The 30-minute threshold is a standard e-commerce convention that balances capturing natural user behavior (e.g., returning to a site after lunch) while avoiding artificial session fragmentation. This allows accurate funnel analysis and prevents inflating session counts.

**Implementation:** Window function `LAG()` compares each event's timestamp to the previous event for the same user; `is_new_session` flag marks boundaries.

---

### 2. Session Sequencing
**Logic:** Sessions are numbered sequentially per user using a running sum of session boundary flags.

**Why:** Enables grouping of events into discrete sessions and supports time-series analysis (e.g., "first session vs. repeat sessions").

**Implementation:** `SUM(is_new_session) OVER (PARTITION BY user_id ORDER BY event_timestamp ROWS UNBOUNDED PRECEDING)` creates a monotonically increasing session counter.

---

### 3. Session-Level Aggregation
**Logic:** For each session, compute:
- **Temporal metrics:** session start/end timestamps, duration in seconds
- **Event metrics:** total event count, distinct pages viewed, purchase/add-to-cart counts
- **Revenue:** sum of event_revenue (using `NVL()` to treat nulls as 0)

**Why:** Enables analysis of user engagement depth, conversion rates, and revenue attribution at the session level rather than individual events.

**Implementation:** `GROUP BY user_id, session_seq` aggregates all events within a session; `COUNT(DISTINCT page_url)` avoids double-counting repeated page visits.

---

### 4. First/Last Touch Attribution
**Logic:** Capture the referrer and device type from the first event in a session, and the referrer from the last event.

**Why:** Supports multi-touch attribution analysis (e.g., "Did users who entered via organic search convert?") and identifies device switching within sessions.

**Implementation:** `FIRST_VALUE()` and `LAST_VALUE()` window functions with `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` frame ensure all rows in the partition are visible for comparison.

**Note:** Device type is captured only at session start; this assumes device consistency within a session (a reasonable assumption for most use cases).

---

### 5. Session Outcome Classification
**Logic:** Sessions are classified into four mutually exclusive categories:
- **Converted:** ≥1 purchase event
- **Engaged:** ≥1 add-to-cart event (but no purchase)
- **Browsing:** ≥4 pages viewed (but no cart/purchase)
- **Bounced:** all other sessions

**Why:** Provides a simple, actionable segmentation for marketing and product teams to identify high-intent vs. low-engagement sessions.

**Implementation:** `CASE` statement with ordered conditions (checked top-to-bottom); note that a session with 1 purchase and 10 pages is classified as "converted," not "browsing."

---

### 6. Session Length Bucketing
**Logic:** Sessions are bucketed into four duration categories:
- **Bounce:** <10 seconds
- **Short:** 10–120 seconds (2 minutes)
- **Medium:** 2–10 minutes
- **Long:** >10 minutes

**Why:** Enables analysis of engagement depth and helps identify bot/spam sessions (very short durations) vs. genuine user exploration.

**Implementation:** Nested `CASE` statement on `session_duration_sec`; thresholds are configurable business rules.

---

### 7. Null Handling & Data Cleaning
**Logic:**
- `WHERE e.user_id IS NOT NULL` filters out events with missing user identifiers (cannot be sessionized).
- `NVL(event_revenue, 0)` treats missing revenue as zero (conservative assumption: if revenue is not recorded, assume no revenue).
- `FIRST_VALUE()` and `LAST_VALUE()` preserve null referrer/device values if all events in a session lack these attributes.

**Why:** Ensures data integrity and prevents null propagation errors; assumes missing revenue is equivalent to zero revenue (not "unknown").

---

## Column Descriptions

| Column | Data Type | Description | Example Values |
|--------|-----------|-------------|-----------------|
| **user_id** | VARCHAR | Unique user identifier from raw events. Primary key (with session_id). | `user_12345`, `cust_abc789` |
| **session_id** | VARCHAR | Unique session identifier from the first event in the session. Used for tracing back to raw events. | `sess_20240115_001` |
| **session_seq** | INT | Sequential session number per user (1 = first session, 2 = second, etc.). Useful for cohort analysis. | `1`, `2`, `15` |
| **session_start** | TIMESTAMP | Timestamp of the first event in the session. | `2024-01-15 09:30:00` |
| **session_end** | TIMESTAMP | Timestamp of the last event in the session. | `2024-01-15 09:45:30` |
| **session_duration_sec** | INT | Total session duration in seconds (session_end - session_start). | `900`, `45`, `3600` |
| **event_count** | INT | Total number of events (clicks, page views, purchases, etc.) in the session. | `5`, `1`, `50` |
| **pages_viewed** | INT | Distinct count of unique page URLs visited in the session. | `3`, `1`, `12` |
| **purchase_count** | INT | Number of purchase events in the session. | `0`, `1`, `2` |
| **add_to_cart_count** | INT | Number of add-to-cart events in the session. | `0`, `1`, `3` |
| **session_revenue** | DECIMAL | Total revenue attributed to the session (sum of event_revenue). | `0.00`, `49.99`, `250.00` |
| **first_touch_referrer** | VARCHAR | Referrer source from the first event in the session (e.g., "google", "direct", "facebook"). | `google`, `direct`, `facebook_ad` |
| **last_touch_referrer** | VARCHAR | Referrer source from the last event in the session. Useful for last-click attribution. | `google`, `direct`, `organic_search` |
| **device_type** | VARCHAR | Device type from the first event in the session (e.g., "mobile", "desktop", "tablet"). | `mobile`, `desktop`, `tablet` |
| **country** | VARCHAR | Country from the first event in the session (geo-location). | `US`, `GB`, `CA` |
| **session_outcome** | VARCHAR | Classification of session result: `converted`, `engaged`, `browsing`, or `bounced`. | `converted`, `bounced` |
| **session_length_bucket** | VARCHAR | Duration category: `bounce`, `short`, `medium`, or `long`. | `short`, `long` |
| **_loaded_at** | TIMESTAMP | Timestamp when this row was inserted (for SCD tracking and debugging). | `2024-01-15 12:00:00` |

---

## Data Quality & Edge Cases

### Null Handling
- **user_id:** Rows with null user_id are filtered out in the `WHERE` clause. If upstream events lack user identification, they are silently dropped. **Risk:** If user_id is frequently null, significant event loss may occur undetected.
- **event_revenue:** Null values are treated as zero via `NVL()`. **Assumption:** Missing revenue = no revenue, not "unknown revenue." If revenue is sometimes null due to data pipeline delays, this will undercount session revenue.
- **referrer, device_type, country:** Null values are preserved in the output. A session may have `first_touch_referrer = NULL` if all events lack referrer data. **Risk:** Downstream filters on these columns may silently exclude sessions.

### Deduplication Strategy
- **No explicit deduplication** is performed. The code assumes `staging.stg_raw_events` is already deduplicated (i.e., no duplicate event rows). **Risk:** If raw events contain duplicates, session metrics (event_count, pages_viewed, revenue) will be inflated.
- **Distinct page URLs** are counted via `COUNT(DISTINCT page_url)`, which handles repeated visits to the same page correctly.

### Key Assumptions
1. **Event timestamps are monotonically increasing per user:** The `LAG()` window function assumes events are already sorted by timestamp. If events arrive out-of-order, session boundaries may be incorrectly detected.
2. **30-minute threshold is appropriate:** This is a fixed business rule. If user behavior changes (e.g., longer typical gaps), sessions may be artificially fragmented.
3. **Device consistency within sessions:** Device type is captured only from the first event. If a user switches devices mid-session, this is not reflected.
4. **Revenue is additive:** The code sums `event_revenue` without deduplication. If a single purchase generates multiple revenue events, revenue will be double-counted.
5. **session_id is unique per session:** The code assumes `MIN(session_id)` returns a consistent identifier. If session_id is not present in raw events or is non-unique, this will fail or produce incorrect results.

### What Could Break
- **Missing or malformed timestamps:** If `event_timestamp` contains nulls or non-timestamp values, the `DATEDIFF()` and window functions will fail.
- **Upstream schema changes:** If `staging.stg_raw_events` drops columns like `referrer` or `device_type`, the query will error.
- **Duplicate events in raw layer:** Session metrics will be inflated; no alerting mechanism exists.
- **Out-of-order events:** If events for a user arrive out of chronological order, session boundaries will be incorrectly detected.
- **Very large sessions:** If a single session contains millions of events, the aggregation may be slow or memory-intensive.

---

## Performance Notes

### Partitioning & Distribution
- **DISTKEY(user_id):** Distributes rows across cluster nodes by user_id. This is optimal because:
  - The window functions partition by user_id, so all events for a user are co-located on the same node.
  - Reduces network traffic during the `LAG()` and `SUM()` window operations.
  - Enables efficient joins downstream on user_id.
  
- **SORTKEY(session_start):** Sorts rows by session start timestamp within each node. Benefits:
  - Accelerates time-range queries (e.g., "sessions in January").
  - Improves compression (temporal locality).
  - Does not directly optimize the window functions (which are already sorted by event_timestamp in the CTE).

### Window Function Performance
- **LAG() in session_boundaries CTE:** O(n) scan per user; efficient because of DISTKEY(user_id).
- **SUM() OVER in session_ids CTE:** O(n log n) due to sorting; acceptable for typical event volumes.
- **FIRST_VALUE() / LAST_VALUE() in session_agg:** O(n) per partition; frame `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` requires scanning the entire partition, but this is necessary to capture first/last values correctly.

### Aggregation Cost
- **GROUP BY user_id, session_seq:** Reduces n events to m sessions (typically m << n). This is the most expensive operation but necessary and unavoidable.
- **COUNT(DISTINCT page_url):** Requires a hash aggregate; acceptable for typical session sizes (<1000 events).

### Full Table Scans
- The query performs a full scan of `staging.stg_raw_events`. If this table is very large (>1B rows), consider:
  - Filtering by date range (e.g., `WHERE event_date >= CURRENT_DATE - 7`) if only recent sessions are needed.
  - Incremental loading (process only new events since last run).

### Estimated Query Time
- For 100M raw events: ~5–15 minutes (depending on cluster size and compression).
- For 1B raw events: ~30–60 minutes.
- **Recommendation:** Run during off-peak hours or use a separate compute cluster.

### Materialization Trade-off
- **Pros:** Pre-computed session metrics are fast for downstream queries; no repeated aggregation.
- **Cons:** Requires storage and must be refreshed regularly; stale data if refresh is infrequent.
- **Alternative:** Could be implemented as a view, but aggregation would be repeated for every downstream query (slower).

---

## Dependencies

### Upstream (Must Run Before This Component)
1. **staging.stg_raw_events** — Raw clickstream events must be loaded and deduplicated. Typically populated by:
   - Event ingestion pipeline (e.g., Segment, Mixpanel, custom logging)
   - Data warehouse ingestion job (e.g., Fivetran, Stitch)
   - **SLA:** Must be available and up-to-date before this transform runs.

### Downstream (Components That Depend on This Output)
1. **marts.fct_customer_sessions** — Fact table for BI reporting; joins session data with customer dimensions.
2. **marts.dim_customer_journey** — Customer dimension table; uses session sequences for cohort analysis.
3. **analytics.attribution_model** — Attribution modeling; uses first/last touch referrer for multi-touch analysis.
4. **dashboards.session_analytics** — Tableau/Looker dashboards; visualizes session outcomes, duration, and conversion rates.
5. **ml_models.churn_prediction** — Machine learning model; uses session metrics as features.
6. **reports.daily_session_summary** — Automated reporting; aggregates session counts and revenue by day/channel.

### External Dependencies
- **None explicitly referenced in code.**
- **Implicit:** Assumes Redshift cluster is available and has sufficient compute/storage capacity.

### Configuration & Assumptions
- **Session timeout:** 30 minutes (hardcoded; consider externalizing to a config table if this needs to change frequently).
- **Revenue null handling:** Treats nulls as zero (could be parameterized).
- **Outcome classification thresholds:** Hardcoded (e.g., "browsing" = >3 pages); consider moving to a lookup table for flexibility.

---

## Maintenance & Monitoring Recommendations

### Data Quality Checks
- **Alert if event_count = 0:** Indicates a session with no events (data quality issue).
- **Alert if session_duration_sec < 0:** Indicates out-of-order events or timestamp corruption.
- **Monitor null rates:** Track % of sessions with null referrer/device_type; sudden spikes indicate upstream issues.

### Refresh Strategy
- **Frequency:** Daily (or more frequently if real-time sessions are needed).
- **Incremental vs. Full:** Currently a full refresh (DROP + CREATE). Consider incremental loading for large tables.
- **Backfill:** If raw events are corrected retroactively, sessions must be recalculated.

### Documentation Maintenance
- Update this document if session timeout threshold changes.
- Document any changes to outcome classification logic.
- Track schema changes to `staging.stg_raw_events` that may impact this transform.