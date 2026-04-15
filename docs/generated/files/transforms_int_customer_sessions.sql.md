# transforms/int_customer_sessions.sql

## Component Overview
- **Layer:** Transforms
- **Type:** Table (materialized)
- **Schedule:** Not specified in code; recommend daily full refresh or incremental load based on event recency
- **Owner:** Not specified in code; recommend Analytics Engineering team

---

## Purpose

This component reconstructs user sessions from raw clickstream events by detecting natural breaks in user activity (>30 minute gaps) and aggregating event-level data into session-level metrics. It serves as a foundational table for customer journey analysis, attribution modeling, and conversion funnel reporting. Downstream analytics, BI dashboards, and data science models depend on this sessionized view to understand user behavior patterns, conversion paths, and engagement quality.

---

## Inputs

- **staging.stg_raw_events** — Raw clickstream events containing user interactions (page views, clicks, purchases, etc.). This component requires `user_id`, `event_timestamp`, `event_type`, `page_url`, `referrer`, `device_type`, `country`, `event_revenue`, and `session_id` fields to reconstruct sessions and compute attribution.

---

## Outputs

- **transforms.int_customer_sessions** — Session-level aggregation table containing one row per user session with metrics including session duration, event counts, revenue, conversion indicators, and first/last touch attribution. Consumed by downstream reporting tables, BI tools (Tableau/Looker), customer segmentation models, and attribution analysis workflows.

---

## Key Business Logic

### 1. Session Boundary Detection
**What:** Events are grouped into sessions using a 30-minute inactivity threshold. Any gap >30 minutes between consecutive events (ordered by timestamp within a user) marks the start of a new session.

**Why:** 30 minutes is a standard industry convention for defining session boundaries in web analytics. It balances capturing related user intent (e.g., browsing → purchase) while separating distinct visits. This threshold should be reviewed annually against actual user behavior patterns.

**Implementation:** The `session_boundaries` CTE uses `LAG()` window function to detect gaps. A new session flag is set when the time delta exceeds 30 minutes or when it's the first event for a user.

---

### 2. Session Sequencing
**What:** Sessions are assigned a sequential number (`session_seq`) per user using a running sum of the session boundary flag.

**Why:** Provides a deterministic, human-readable session identifier that works alongside the raw `session_id` from events. Enables easy ranking of sessions (e.g., "user's 5th session").

**Implementation:** `SUM(is_new_session) OVER (PARTITION BY user_id ORDER BY event_timestamp ROWS UNBOUNDED PRECEDING)` creates a cumulative counter that increments at each session boundary.

---

### 3. Session-Level Aggregation
**What:** Events within each session are aggregated to compute:
- **Temporal metrics:** session start/end timestamps, duration in seconds
- **Activity metrics:** total event count, distinct pages viewed
- **Conversion metrics:** purchase count, add-to-cart count, total revenue
- **Attribution metrics:** first/last touch referrer and device type

**Why:** Reduces dimensionality from event-level to session-level, enabling efficient analysis of user journeys. Conversion and revenue metrics are critical for ROI calculations and funnel analysis.

**Implementation:** 
- Aggregation uses `MIN()` and `MAX()` for temporal bounds
- `DATEDIFF(second, ...)` computes session duration
- `SUM(CASE WHEN event_type = 'purchase' ...)` counts specific event types
- `FIRST_VALUE()` and `LAST_VALUE()` window functions capture first/last touch attribution across the session window

---

### 4. Session Outcome Classification
**What:** Sessions are labeled into four mutually exclusive categories:
- **converted:** ≥1 purchase event
- **engaged:** ≥1 add-to-cart event (but no purchase)
- **browsing:** ≥4 pages viewed (but no cart/purchase)
- **bounced:** all other sessions

**Why:** Provides a simple, actionable segmentation for marketing and product teams. Enables cohort analysis (e.g., "what drives bounced sessions to convert?").

**Business Rule:** Hierarchy is intentional—a session with both a purchase and add-to-cart is classified as "converted" (highest value outcome). This prevents double-counting in downstream reporting.

---

### 5. Session Length Bucketing
**What:** Sessions are categorized by duration:
- **bounce:** <10 seconds
- **short:** 10–120 seconds (2 minutes)
- **medium:** 2–10 minutes
- **long:** >10 minutes

**Why:** Duration correlates with engagement quality and intent. Short sessions often indicate accidental clicks or bot traffic; long sessions suggest high engagement or comparison shopping.

**Assumption:** These thresholds are based on typical e-commerce behavior and should be validated against your specific domain (e.g., SaaS products may have different patterns).

---

### 6. Null Handling
**What:** 
- `WHERE e.user_id IS NOT NULL` filters out events without user identification
- `NVL(event_revenue, 0)` treats missing revenue as zero (safe for SUM aggregation)
- `FIRST_VALUE()` and `LAST_VALUE()` preserve NULL referrers/device types if no non-null values exist in the session

**Why:** Prevents orphaned sessions without user context. Revenue nulls are treated as zero to avoid skewing session_revenue calculations.

**Risk:** If `event_revenue` is NULL for legitimate reasons (e.g., non-transactional events), this logic is correct. If NULL indicates missing data, investigate upstream data quality.

---

## Column Descriptions

| Column | Data Type | Description | Example Values |
|--------|-----------|-------------|-----------------|
| **user_id** | VARCHAR | Unique user identifier from raw events | `user_12345`, `cust_abc123` |
| **session_id** | VARCHAR | Session identifier from raw events; may not be unique if events lack session IDs | `sess_xyz789` |
| **session_seq** | INTEGER | Sequence number of this session for the user (1st, 2nd, 3rd, etc.) | `1`, `5`, `42` |
| **session_start** | TIMESTAMP | Timestamp of the first event in the session | `2024-01-15 10:30:45` |
| **session_end** | TIMESTAMP | Timestamp of the last event in the session | `2024-01-15 10:45:12` |
| **session_duration_sec** | INTEGER | Total session duration in seconds | `894`, `45`, `3600` |
| **event_count** | INTEGER | Total number of events (page views, clicks, etc.) in the session | `12`, `1`, `50` |
| **pages_viewed** | INTEGER | Count of distinct page URLs visited in the session | `5`, `1`, `20` |
| **purchase_count** | INTEGER | Number of purchase events in the session | `0`, `1`, `3` |
| **add_to_cart_count** | INTEGER | Number of add-to-cart events in the session | `0`, `2`, `1` |
| **session_revenue** | DECIMAL | Total revenue attributed to the session (sum of event_revenue) | `0.00`, `49.99`, `1250.50` |
| **first_touch_referrer** | VARCHAR | Referrer source of the first event in the session (attribution) | `google`, `direct`, `facebook`, NULL |
| **last_touch_referrer** | VARCHAR | Referrer source of the last event in the session (attribution) | `google`, `direct`, NULL |
| **device_type** | VARCHAR | Device type from the first event (assumed constant within session) | `mobile`, `desktop`, `tablet` |
| **country** | VARCHAR | Country from the first event (assumed constant within session) | `US`, `GB`, `CA` |
| **session_outcome** | VARCHAR | Classification of session quality/conversion status | `converted`, `engaged`, `browsing`, `bounced` |
| **session_length_bucket** | VARCHAR | Duration-based session category | `bounce`, `short`, `medium`, `long` |
| **_loaded_at** | TIMESTAMP | Timestamp when this row was inserted (data lineage) | `2024-01-16 02:30:00` |

---

## Data Quality & Edge Cases

### Null Handling
- **user_id:** Rows with NULL user_id are filtered out in `session_boundaries` CTE. This prevents orphaned sessions but may hide data quality issues upstream. **Recommendation:** Monitor the count of dropped events and alert if >5% of raw events lack user_id.
- **event_revenue:** NULL values are treated as zero in `SUM(NVL(event_revenue, 0))`. This is safe for aggregation but masks missing data. **Recommendation:** Track sessions with NULL revenue separately to detect data collection gaps.
- **referrer, device_type, country:** If all events in a session have NULL values, the output column will be NULL. This is correct behavior but may indicate incomplete event tracking.

### Deduplication Strategy
- **No explicit deduplication:** The code assumes `staging.stg_raw_events` is already deduplicated. If raw events contain duplicates (e.g., from retries or double-logging), they will inflate `event_count` and `session_revenue`.
- **Recommendation:** Add a deduplication step in the staging layer (e.g., `ROW_NUMBER() OVER (PARTITION BY user_id, event_timestamp, event_type ORDER BY _loaded_at DESC)`) or validate upstream.

### Session ID Assumption
- **Potential Issue:** The code uses `MIN(session_id)` from raw events, assuming a session_id field exists and is consistent within a session. If raw events lack session_id or have inconsistent values, this column will be unreliable.
- **Recommendation:** Validate that `session_id` is populated and consistent in staging.stg_raw_events. Consider making session_id a composite key: `CONCAT(user_id, '_', session_seq)` for guaranteed uniqueness.

### Device Type & Country Assumptions
- **Assumption:** Device type and country are constant within a session. If a user switches devices mid-session (e.g., mobile → desktop), only the first device is captured.
- **Impact:** Low for most use cases, but may undercount cross-device sessions. If this is important, consider adding `device_type_changes` and `country_changes` columns.

### 30-Minute Threshold Sensitivity
- **Assumption:** 30 minutes is the correct session boundary. If your business defines sessions differently (e.g., 15 minutes for mobile, 60 minutes for desktop), this logic will misclassify sessions.
- **Recommendation:** Parameterize the threshold (e.g., `DECLARE @session_gap_minutes = 30`) and document the business rationale. Review annually against actual user behavior.

### Bounced Session Definition
- **Current Logic:** Sessions with <4 pages viewed AND no cart/purchase events are labeled "bounced."
- **Potential Issue:** A user who views 1 high-value product page and leaves is classified as "bounced" despite high intent. This may not reflect business reality.
- **Recommendation:** Consider adding intent signals (e.g., time on page, scroll depth) or consulting with product/marketing teams on the definition.

---

## Performance Notes

### Partitioning & Distribution
- **DISTKEY(user_id):** Distributes rows across cluster nodes by user_id. This is optimal for queries filtering by user (e.g., "all sessions for user X") and for the window functions partitioned by user_id. Ensures related data is co-located on the same node, reducing network traffic.
- **SORTKEY(session_start):** Sorts rows by session start timestamp within each node. Enables efficient range scans for time-based queries (e.g., "sessions in January 2024"). Consider adding a compound sort key: `SORTKEY(user_id, session_start)` for better performance on user + time filters.

### Window Function Efficiency
- **FIRST_VALUE() and LAST_VALUE():** These are computed per session using `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING`. This requires scanning the entire session window for each row, which is expensive for large sessions (e.g., 1000+ events).
- **Optimization:** These are computed in the `session_agg` CTE *before* the GROUP BY, meaning they're recalculated for every event row. Consider moving the window functions *after* the GROUP BY or using a different approach (e.g., `MIN(CASE WHEN rn=1 THEN referrer END)` with row numbering).

### Aggregation Strategy
- **GROUP BY user_id, session_seq:** This is efficient because the data is already partitioned by user_id (DISTKEY). The GROUP BY operates on pre-sorted, co-located data.
- **Potential Bottleneck:** If `staging.stg_raw_events` is very large (billions of rows), the initial window functions in `session_boundaries` and `session_ids` CTEs will be expensive. Consider filtering by date range (e.g., `WHERE event_timestamp >= CURRENT_DATE - 90`) if historical data is not needed.

### Full Table Scan
- **Current Behavior:** The query scans all of `staging.stg_raw_events` without a date filter. This is necessary for accurate session reconstruction (a session may span multiple days) but can be slow on large tables.
- **Recommendation:** If incremental loading is desired, implement a watermark-based approach: load only events with `event_timestamp >= MAX(session_end) - 1 day` from the previous run, then merge with existing sessions.

### Materialization vs. View
- **Current:** Table is materialized (CREATE TABLE AS). This trades storage for query speed. Downstream queries will be fast but the table must be refreshed regularly.
- **Alternative:** If real-time sessions are needed, consider a view or materialized view with incremental refresh. Trade-off: slower downstream queries but always current.

---

## Dependencies

### Upstream
- **staging.stg_raw_events** — Must be loaded and deduplicated before this transform runs. Ensure:
  - All required columns are present: `user_id`, `event_timestamp`, `event_type`, `page_url`, `referrer`, `device_type`, `country`, `event_revenue`, `session_id`
  - `event_timestamp` is in UTC and non-null
  - No duplicate events (or duplicates are acceptable for your use case)
  - Data freshness: typically loaded daily or hourly depending on business requirements

### Downstream
- **Reporting tables** (e.g., `reports.customer_journey`, `reports.conversion_funnel`) — Depend on `int_customer_sessions` for session-level metrics and outcome classifications
- **BI dashboards** (Tableau, Looker, etc.) — Query this table directly for session analytics, user segmentation, and cohort analysis
- **Data science models** — Use session features (duration, outcome, revenue) for churn prediction, LTV modeling, and recommendation engines
- **Attribution models** — Consume `first_touch_referrer` and `last_touch_referrer` for multi-touch attribution analysis
- **Customer segmentation** — Use `session_outcome` and `session_length_bucket` to define customer cohorts (e.g., "high-value converters," "at-risk bouncers")

### External
- **No external APIs or systems referenced** in this code
- **Implicit dependency:** Assumes Redshift-specific SQL syntax (DISTKEY, SORTKEY, DATEDIFF, GETDATE, ANALYZE). Not portable to other databases without modification.

---

## Maintenance & Monitoring Recommendations

### Data Quality Checks
1. **Null user_id rate:** Alert if >5% of raw events are dropped due to missing user_id
2. **Session duration outliers:** Flag sessions >24 hours (likely data quality issues)
3. **Revenue validation:** Ensure `session_revenue` ≥ 0 (no negative revenue unless refunds are expected)
4. **Referrer coverage:** Monitor % of sessions with NULL first_touch_referrer; high rates indicate tracking gaps

### Performance Monitoring
1. **Query runtime:** Track execution time; alert if >30 minutes (indicates upstream data growth or need for optimization)
2. **Table size:** Monitor row count and storage; alert if growing unexpectedly
3. **Vacuum & analyze:** Schedule regular VACUUM and ANALYZE operations to maintain query performance

### Refresh Strategy
- **Current:** Full table refresh (DROP + CREATE). Consider incremental loading for large tables.
- **Recommended:** Daily full refresh if data volume is <1B rows; otherwise, implement incremental merge logic.