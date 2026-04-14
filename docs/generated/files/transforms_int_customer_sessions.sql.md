# transforms/int_customer_sessions.sql

## Component Overview
- **Layer:** Transforms
- **Type:** Table (materialized)
- **Schedule:** Not specified in code; recommend daily full refresh or incremental load based on event recency
- **Owner:** Not specified in code; recommend Analytics Engineering team

---

## Purpose

This component reconstructs user sessions from raw clickstream events by detecting natural breaks in user activity (>30 minute gaps) and aggregating event-level data into session-level metrics. It serves as a foundational table for customer journey analysis, conversion funnel reporting, and attribution modeling. Downstream analytics, BI dashboards, and data science models depend on this sessionized view to understand customer behavior patterns, engagement levels, and purchase intent.

---

## Inputs

- **staging.stg_raw_events** — Raw clickstream events with user identifiers, timestamps, event types (page views, clicks, purchases), device/location attributes, and revenue data. This component requires this table to be complete, deduplicated, and have valid timestamps for accurate session boundary detection.

---

## Outputs

- **transforms.int_customer_sessions** — Session-level aggregated metrics including session identifiers, duration, event counts, conversion indicators, attribution touchpoints, and behavioral classifications. Consumed by downstream reporting tables (marts), BI tools, customer segmentation models, and attribution analysis workflows.

---

## Key Business Logic

### 1. **Session Boundary Detection (session_boundaries CTE)**
Identifies when a user's activity session begins or ends by detecting inactivity gaps exceeding 30 minutes. A new session is flagged when:
- The time gap between consecutive events (ordered by timestamp) exceeds 30 minutes, OR
- An event is the first event for a user (no prior event exists)

**Why:** 30 minutes is a standard industry heuristic for session timeout; it balances capturing related user actions while avoiding artificially merging distinct visit intentions. This threshold should be configurable based on business domain (e.g., news sites may use 15 min; e-commerce may use 45 min).

### 2. **Session ID Assignment (session_ids CTE)**
Assigns a cumulative session sequence number (`session_seq`) to each event by summing the `is_new_session` flag in order within each user partition. This creates a unique session identifier per user.

**Why:** Enables grouping of all events belonging to the same session in the aggregation step. The sequence number is deterministic and reproducible across runs.

### 3. **Session-Level Aggregation (session_agg CTE)**
Computes metrics at the session grain:

- **Temporal metrics:** `session_start`, `session_end`, `session_duration_sec` — capture when the session occurred and how long the user was active.
- **Engagement metrics:** `event_count`, `pages_viewed`, `purchase_count`, `add_to_cart_count` — quantify user interaction intensity and purchase signals.
- **Revenue metric:** `session_revenue` — sums all transaction amounts in the session (using `NVL` to treat nulls as 0).
- **Attribution metrics:** `first_touch_referrer`, `last_touch_referrer` — capture the initial and final traffic source for the session, enabling first-touch and last-touch attribution models.
- **Contextual attributes:** `device_type`, `country` — captured from the first event in the session (assumed constant within a session).

**Why:** Session-level aggregation reduces data volume, enables faster reporting queries, and provides a natural unit of analysis for customer journey work. First/last touch attribution supports multi-touch attribution analysis.

### 4. **Session Outcome Classification**
A derived column that segments sessions into business-relevant categories:
- **"converted"** — session contains ≥1 purchase event (highest intent)
- **"engaged"** — session contains add-to-cart events but no purchase (mid-funnel)
- **"browsing"** — session has >3 pages viewed but no conversion signals (exploration)
- **"bounced"** — session has ≤3 pages and no conversion signals (low engagement)

**Why:** Enables quick funnel analysis and cohort segmentation without requiring downstream case logic. Supports marketing attribution and campaign effectiveness measurement.

### 5. **Session Length Bucketing**
Categorizes sessions by duration:
- **"bounce"** — <10 seconds (likely accidental or bot traffic)
- **"short"** — 10 seconds to 2 minutes (quick task completion)
- **"medium"** — 2 to 10 minutes (typical browsing)
- **"long"** — >10 minutes (deep engagement or research)

**Why:** Provides a simple engagement proxy; enables segmentation of user behavior patterns and identification of high-intent vs. low-intent sessions.

### 6. **Data Lineage Tracking**
`_loaded_at` column records the exact timestamp when the table was materialized, enabling incremental load logic and data freshness monitoring.

---

## Column Descriptions

| Column | Type | Description | Example Values |
|--------|------|-------------|-----------------|
| **user_id** | VARCHAR | Unique identifier for the customer/user. Primary key component. | `user_12345`, `cust_abc789` |
| **session_id** | VARCHAR | Unique identifier for the session (from raw events). May not be globally unique; use `(user_id, session_seq)` as composite key. | `sess_001`, `s_9876543` |
| **session_seq** | INT | Cumulative session sequence number per user (1st session, 2nd session, etc.). Enables ordering of user's sessions chronologically. | `1`, `2`, `15` |
| **session_start** | TIMESTAMP | Timestamp of the first event in the session. | `2024-01-15 09:30:00` |
| **session_end** | TIMESTAMP | Timestamp of the last event in the session. | `2024-01-15 09:45:30` |
| **session_duration_sec** | INT | Total duration of the session in seconds (session_end - session_start). | `900`, `45`, `3600` |
| **event_count** | INT | Total number of events (page views, clicks, etc.) in the session. | `5`, `1`, `50` |
| **pages_viewed** | INT | Count of distinct page URLs visited in the session. | `3`, `1`, `12` |
| **purchase_count** | INT | Number of purchase events in the session. | `0`, `1`, `2` |
| **add_to_cart_count** | INT | Number of add-to-cart events in the session. | `0`, `1`, `3` |
| **session_revenue** | DECIMAL | Total revenue generated in the session (sum of `event_revenue` from all events). | `0.00`, `49.99`, `250.00` |
| **first_touch_referrer** | VARCHAR | Traffic source/referrer of the first event in the session (e.g., "google", "facebook", "direct"). | `"google"`, `"direct"`, `"facebook_ad"` |
| **last_touch_referrer** | VARCHAR | Traffic source/referrer of the last event in the session. May differ from first_touch if user navigated between channels. | `"google"`, `"direct"`, `"email"` |
| **device_type** | VARCHAR | Device category of the first event (assumed constant for the session). | `"mobile"`, `"desktop"`, `"tablet"` |
| **country** | VARCHAR | Country of the first event (assumed constant for the session). | `"US"`, `"GB"`, `"CA"` |
| **session_outcome** | VARCHAR | Business classification of session intent/result. | `"converted"`, `"engaged"`, `"browsing"`, `"bounced"` |
| **session_length_bucket** | VARCHAR | Engagement intensity category based on duration. | `"bounce"`, `"short"`, `"medium"`, `"long"` |
| **_loaded_at** | TIMESTAMP | Timestamp when this row was inserted into the table (data lineage). | `2024-01-16 02:30:00` |

---

## Data Quality & Edge Cases

### Null Handling
- **user_id:** Rows with NULL `user_id` are **filtered out** in the `session_boundaries` CTE (`WHERE e.user_id IS NOT NULL`). This is appropriate for sessionization but means anonymous/unidentified traffic is excluded. **Risk:** If a significant portion of traffic is unidentified, this table will undercount total sessions.
- **event_revenue:** Treated as 0 if NULL using `NVL(event_revenue, 0)` in the revenue sum. **Assumption:** NULL revenue means no transaction value, not missing data. If revenue is sometimes NULL due to data collection errors, this will undercount session revenue.
- **referrer, device_type, country:** Captured from the first event in the session using `FIRST_VALUE()`. If these are NULL in the first event, they will be NULL in the session record. **Risk:** If device or location data is sparse, session-level attributes may be incomplete.

### Deduplication Strategy
- **No explicit deduplication** of raw events is performed. The code assumes `staging.stg_raw_events` is already deduplicated. **Risk:** If duplicate events exist upstream (e.g., due to ETL retries or client-side double-tracking), they will inflate `event_count`, `pages_viewed`, and revenue metrics.
- **Recommendation:** Add a deduplication step in the staging layer or validate that `stg_raw_events` has a unique constraint on `(user_id, event_id, event_timestamp)`.

### Session Boundary Assumptions
- **30-minute inactivity threshold is fixed.** If business requirements change (e.g., mobile vs. desktop sessions have different timeouts), this logic must be updated. **Risk:** Suboptimal session definitions if threshold doesn't match actual user behavior.
- **Assumes event_timestamp is accurate and in correct timezone.** If timestamps are in mixed timezones or have clock skew, session boundaries may be incorrectly detected.
- **Assumes events are ordered by timestamp within a user.** If events arrive out-of-order in the source, the LAG window function may produce incorrect session breaks.

### Edge Cases
1. **Single-event sessions:** Sessions with only 1 event will have `session_start == session_end` and `session_duration_sec = 0`, classified as "bounce". This is correct behavior.
2. **Sessions spanning midnight:** If a user is active across midnight, the session will correctly span both days (no automatic reset at midnight). This is appropriate for web sessions.
3. **Users with no events:** Will not appear in this table (no rows generated). This is expected.
4. **Very long sessions (>24 hours):** Possible if a user leaves a browser tab open. The 30-minute rule will not break these into separate sessions. **Risk:** May inflate engagement metrics for inactive users. **Mitigation:** Consider adding a maximum session duration cap (e.g., 8 hours).
5. **Revenue without purchase event:** If `event_revenue` is populated on non-purchase events (e.g., ad impressions), `session_revenue` will include this, but `purchase_count` will be 0. This could misclassify sessions as "engaged" instead of "converted". **Risk:** Requires validation that revenue is only populated on purchase events.

---

## Performance Notes

### Partitioning & Distribution
- **DISTKEY(user_id):** Distributes rows across cluster nodes by user ID. **Benefit:** All events for a user are co-located, making window functions over `PARTITION BY user_id` efficient. **Trade-off:** If user ID distribution is skewed (e.g., a few power users), some nodes may be overloaded.
- **SORTKEY(session_start):** Sorts rows by session start time within each node. **Benefit:** Enables efficient range scans for time-based queries (e.g., "sessions in January"). **Trade-off:** Slows down inserts/updates; only beneficial if queries frequently filter by time.

### Window Function Performance
- **LAG() and FIRST_VALUE/LAST_VALUE window functions** are computed over `PARTITION BY user_id` and `ORDER BY event_timestamp`. These are **expensive operations** on large datasets:
  - LAG requires sorting events per user, which can spill to disk if user has many events.
  - FIRST_VALUE/LAST_VALUE with `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` require scanning the entire partition.
  - **Recommendation:** For tables with >100M events, consider materializing session boundaries incrementally or using a more efficient sessionization algorithm (e.g., gap-and-island with ROW_NUMBER).

### Aggregation Performance
- **GROUP BY user_id, session_seq** in the `session_agg` CTE reduces the dataset significantly (from event-level to session-level). This is efficient.
- **COUNT(DISTINCT page_url)** requires a hash aggregation, which is moderately expensive. For sessions with many pages, this could be a bottleneck.

### Full Table Scan
- **No WHERE clause filters** in the final SELECT, so the entire `session_agg` result set is written to the output table. If only recent sessions are needed, consider adding a filter (e.g., `WHERE session_start >= CURRENT_DATE - 1`).

### Estimated Complexity
- **Time complexity:** O(n log n) per user (due to sorting for window functions), where n = events per user.
- **Space complexity:** O(n) for intermediate CTEs.
- **For 1B events across 10M users:** Expect 2–4 hours on a 4-node Redshift cluster (depending on node type and data skew).

---

## Dependencies

### Upstream (Must Run Before This Component)
- **staging.stg_raw_events** — Raw event ingestion pipeline. Must complete successfully and be deduplicated before this transform runs. If this table is incomplete or has late-arriving data, session boundaries will be incorrect.
- **Data quality checks on stg_raw_events** — Recommend validating:
  - No NULL user_ids (or document expected null rate)
  - event_timestamp is not NULL and is in valid range
  - event_type values are known (purchase, add_to_cart, page_view, etc.)
  - event_revenue is non-negative (if populated)

### Downstream (Depends on This Component)
- **marts.fct_customer_sessions** — Likely a fact table that joins this table with dimension tables (users, products, campaigns) for BI reporting.
- **marts.dim_customer_behavior** — Customer segmentation or RFM analysis that uses session_outcome and session_length_bucket.
- **Attribution models** — Multi-touch attribution logic that consumes first_touch_referrer and last_touch_referrer.
- **Funnel analysis dashboards** — BI tools that query session_outcome to build conversion funnels.
- **Customer journey analysis** — Data science models that reconstruct user paths using session_seq and session_start.

### External Dependencies
- **None explicitly referenced.** However, the code assumes:
  - Redshift-specific SQL syntax (DATEDIFF, GETDATE, DISTKEY, SORTKEY, ANALYZE, GRANT).
  - A schema named `transforms` and `staging` exists.
  - A user group `analytics_readers` exists for GRANT permissions.

---

## Recommendations for Production Hardening

1. **Add data quality checks:**
   ```sql
   -- Validate no sessions with negative duration
   SELECT COUNT(*) FROM transforms.int_customer_sessions 
   WHERE session_duration_sec < 0;
   
   -- Validate session_end >= session_start
   SELECT COUNT(*) FROM transforms.int_customer_sessions 
   WHERE session_end < session_start;
   ```

2. **Make session timeout configurable:**
   - Store the 30-minute threshold in a config table to enable A/B testing of different thresholds.

3. **Add incremental load logic:**
   - Instead of `DROP TABLE IF EXISTS`, implement an incremental upsert to avoid full recomputation.

4. **Monitor for data skew:**
   - Track distribution of events per user; alert if a single user has >1M events (potential bot or data quality issue).

5. **Document assumptions in code comments:**
   - Add comments explaining why 30 minutes was chosen and when it should be revisited.

6. **Add session validation:**
   - Ensure `session_seq` is contiguous per user (no gaps), indicating correct session assignment.