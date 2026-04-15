# transforms/int_customer_sessions.sql

## Component Overview
- **Layer:** Transforms
- **Type:** Table (materialized)
- **Schedule:** Not specified in code; recommend daily or continuous based on event ingestion cadence
- **Owner:** Not specified in code; recommend Analytics Engineering or Product Analytics team

---

## Purpose

This component reconstructs user sessions from raw clickstream events by detecting natural breaks in user activity (>30 minute gaps) and aggregating event-level data into session-level metrics. It serves as a foundational table for customer journey analysis, attribution modeling, and conversion funnel reporting. Downstream analytics, BI dashboards, and data science models depend on this sessionized view to understand user behavior patterns, engagement levels, and purchase intent.

---

## Inputs

- **staging.stg_raw_events** — Raw clickstream events with timestamps, user identifiers, event types (page views, clicks, purchases), referrer information, device/location attributes, and optional revenue values. This component requires this table to be complete and deduplicated at the event level before sessionization logic is applied.

---

## Outputs

- **transforms.int_customer_sessions** — Session-level aggregated table containing one row per user session with computed metrics (duration, event count, revenue), attribution fields (first/last touch referrer), engagement classifications, and session outcome labels. Consumed by downstream BI tools, attribution models, customer segmentation pipelines, and funnel analysis queries.

---

## Key Business Logic

### 1. Session Boundary Detection
**What:** Events are grouped into sessions using a 30-minute inactivity threshold. Any gap >30 minutes between consecutive events (ordered by timestamp within a user) triggers a new session.

**Why:** 30 minutes is a standard industry convention for defining session boundaries in web analytics. It balances capturing related user intents (e.g., browsing → purchase) while separating distinct visits. This threshold should be validated against your product's typical user behavior.

**Implementation:** The `session_boundaries` CTE uses `LAG()` to compare each event's timestamp to the previous event's timestamp. A flag (`is_new_session`) is set to 1 when the gap exceeds 30 minutes or when it's the first event for a user.

---

### 2. Session Sequencing
**What:** A cumulative sum of the `is_new_session` flag creates a unique session sequence number (`session_seq`) per user.

**Why:** This allows grouping of events into logical sessions without relying on a pre-computed session ID from upstream systems (which may not exist or may be unreliable).

**Implementation:** `SUM(is_new_session) OVER (PARTITION BY user_id ORDER BY event_timestamp ROWS UNBOUNDED PRECEDING)` creates an incrementing counter that resets per user.

---

### 3. Session-Level Aggregation
**What:** Events within each session are aggregated to compute:
- **Temporal metrics:** session start/end timestamps, duration in seconds
- **Activity metrics:** total event count, distinct pages viewed
- **Conversion metrics:** purchase count, add-to-cart count, total revenue
- **Attribution fields:** first and last referrer, device type, country (all captured from first event in session)

**Why:** 
- Temporal metrics enable engagement analysis and funnel timing studies.
- Activity metrics (pages viewed, event count) are proxies for user intent and engagement depth.
- Conversion metrics directly measure business outcomes.
- Attribution fields (first/last touch) support multi-touch attribution models and channel analysis.
- Device and country are captured from the first event to establish session context (assumed stable within a session).

**Implementation:** 
- Aggregation uses `MIN()` and `MAX()` for temporal boundaries.
- `SUM()` and `COUNT()` for metrics.
- `FIRST_VALUE()` and `LAST_VALUE()` window functions with `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` to capture first/last event attributes across the entire session window.

---

### 4. Session Outcome Classification
**What:** Sessions are labeled into four mutually exclusive categories based on conversion and engagement signals:
- **converted:** ≥1 purchase event
- **engaged:** ≥1 add-to-cart event (but no purchase)
- **browsing:** ≥4 pages viewed (but no cart/purchase)
- **bounced:** all other sessions

**Why:** This classification enables quick segmentation for marketing, product, and retention teams. It answers: "Which sessions led to revenue, which showed intent, which were exploratory, and which abandoned immediately?"

**Business Rule:** The hierarchy (purchase > cart > pages > bounce) reflects business priority: conversions are most valuable, followed by demonstrated intent, then exploration, then abandonment.

---

### 5. Session Length Bucketing
**What:** Sessions are categorized by duration into four buckets:
- **bounce:** <10 seconds
- **short:** 10 seconds to <2 minutes
- **medium:** 2 to <10 minutes
- **long:** ≥10 minutes

**Why:** Duration is a proxy for engagement quality and user intent. Bounce sessions often indicate poor landing page experience or off-target traffic. Longer sessions correlate with higher conversion likelihood and are valuable for understanding user commitment.

**Thresholds:** These are industry-standard conventions but should be validated against your product's baseline behavior (e.g., if your average session is 2 minutes, these buckets may need adjustment).

---

### 6. Null Handling & Revenue Aggregation
**What:** `NVL(event_revenue, 0)` treats missing revenue values as zero when summing session revenue.

**Why:** Not all events have associated revenue (e.g., page views, clicks). Treating nulls as zero ensures that sessions without explicit revenue events still aggregate correctly without skewing totals.

**Assumption:** This assumes that missing revenue is equivalent to zero revenue, not unknown/unmeasured revenue. If revenue can be null for legitimate reasons (e.g., pending transactions), this logic may need refinement.

---

## Column Descriptions

| Column | Data Type | Description | Example Values |
|--------|-----------|-------------|-----------------|
| **user_id** | VARCHAR | Unique identifier for the user; used as partition key for distribution. | `user_12345`, `cust_abc123` |
| **session_id** | VARCHAR | Unique identifier for the session (inherited from first event in session). | `sess_20240115_001` |
| **session_seq** | INT | Sequence number of session for this user (1st session = 1, 2nd = 2, etc.). | `1`, `5`, `42` |
| **session_start** | TIMESTAMP | Timestamp of the first event in the session. | `2024-01-15 10:30:45` |
| **session_end** | TIMESTAMP | Timestamp of the last event in the session. | `2024-01-15 10:45:12` |
| **session_duration_sec** | INT | Total duration of session in seconds (end - start). | `900`, `45`, `3600` |
| **event_count** | INT | Total number of events (page views, clicks, etc.) in the session. | `5`, `1`, `50` |
| **pages_viewed** | INT | Count of distinct page URLs visited during the session. | `3`, `1`, `12` |
| **purchase_count** | INT | Number of purchase events in the session. | `0`, `1`, `2` |
| **add_to_cart_count** | INT | Number of add-to-cart events in the session. | `0`, `1`, `3` |
| **session_revenue** | DECIMAL | Total revenue attributed to the session (sum of event_revenue). | `0.00`, `49.99`, `250.00` |
| **first_touch_referrer** | VARCHAR | Referrer source of the first event in the session (attribution starting point). | `google`, `direct`, `facebook.com` |
| **last_touch_referrer** | VARCHAR | Referrer source of the last event in the session (attribution ending point). | `google`, `direct`, `email` |
| **device_type** | VARCHAR | Device category of the first event (assumed constant for session). | `mobile`, `desktop`, `tablet` |
| **country** | VARCHAR | Country of the first event (assumed constant for session). | `US`, `GB`, `CA` |
| **session_outcome** | VARCHAR | Classification of session result (converted, engaged, browsing, bounced). | `converted`, `bounced` |
| **session_length_bucket** | VARCHAR | Duration category for the session. | `short`, `long`, `bounce` |
| **_loaded_at** | TIMESTAMP | Timestamp when this row was inserted (data freshness marker). | `2024-01-15 12:00:00` |

---

## Data Quality & Edge Cases

### Null Handling
- **user_id:** Rows with `NULL user_id` are filtered out in `session_boundaries` (`WHERE e.user_id IS NOT NULL`). Sessions cannot be formed without a user identifier. **Risk:** If upstream data has user_id nulls due to tracking failures, these events are silently dropped. Monitor for unexpected drops in event volume.
- **event_revenue:** Treated as zero via `NVL()`. Sessions with no revenue events will have `session_revenue = 0.00`. **Risk:** Cannot distinguish between "no purchases" and "purchases with unmeasured revenue."
- **referrer, device_type, country:** Captured from first event only. If these attributes are missing in the first event, the session will inherit nulls. **Risk:** Downstream queries must handle nulls in attribution fields.

### Deduplication Strategy
- **No explicit deduplication:** This component assumes `staging.stg_raw_events` is already deduplicated at the event level. If duplicate events exist upstream, they will inflate session metrics (event_count, pages_viewed, purchase_count, session_revenue).
- **Recommendation:** Add a data quality check to validate that `stg_raw_events` has no duplicate (user_id, event_id, event_timestamp) tuples before this transform runs.

### Key Assumptions
1. **Event timestamps are accurate and in chronological order per user.** If timestamps are out of order or skewed, session boundaries will be incorrectly detected.
2. **30-minute threshold is appropriate for your product.** If users typically have longer gaps between related actions (e.g., multi-day shopping carts), sessions may be over-fragmented.
3. **Device type and country are stable within a session.** If a user switches devices mid-session, only the first device is captured. This may misrepresent multi-device journeys.
4. **Revenue is only captured in event_revenue field.** If revenue is recorded elsewhere (e.g., in a separate transactions table), it will be missed.
5. **First event in a session is representative.** Attribution and context (referrer, device, country) are all derived from the first event, which may not reflect the user's true intent if they arrived via one channel and converted via another.

### Potential Data Quality Issues
- **Missing session_id in upstream events:** The code uses `MIN(session_id)` from the first event. If session_id is not pre-computed upstream, this will be null for all rows. **Mitigation:** Either pre-compute session_id upstream or generate it here (e.g., `CONCAT(user_id, '_', session_seq, '_', TO_CHAR(session_start, 'YYYYMMDD'))`).
- **Timezone inconsistencies:** If event_timestamp is in mixed timezones, the 30-minute gap calculation will be incorrect. **Mitigation:** Ensure all timestamps are normalized to UTC upstream.
- **User ID changes:** If a user is tracked with different user_ids across sessions (e.g., before/after login), sessions will be fragmented across identities. **Mitigation:** Implement user identity resolution upstream.

---

## Performance Notes

### Distribution & Sorting Strategy
- **DISTKEY(user_id):** Distributes rows across cluster nodes by user_id. This co-locates all events and sessions for a user on the same node, enabling efficient window functions (`LAG()`, `FIRST_VALUE()`, `LAST_VALUE()`) that partition by user_id. **Implication:** Queries filtering by user_id will be fast; queries filtering by other dimensions (e.g., country, device_type) may require cross-node scans.
- **SORTKEY(session_start):** Sorts rows by session start timestamp within each node. Enables efficient range scans on time-based queries (e.g., "sessions in January"). **Implication:** Queries on session_start will be faster; queries on other columns may require full scans.

### Window Function Performance
- **LAG() in session_boundaries:** Requires a full sort of events per user by timestamp. With millions of users and events, this is expensive but necessary for correctness.
- **FIRST_VALUE() and LAST_VALUE() with ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING:** These require scanning the entire session window for each row before aggregation. This is redundant because the subsequent `GROUP BY` will aggregate anyway. **Optimization opportunity:** Move these window functions to a separate CTE after aggregation, or compute them directly in the aggregation using `MIN()` and `MAX()` on the raw columns (if the first/last event's attributes are deterministic).

### Aggregation Complexity
- **GROUP BY user_id, session_seq:** After window functions, the aggregation groups by two columns. This is efficient because session_seq is already ordered and co-located by user_id.
- **COUNT(DISTINCT page_url):** Requires a hash aggregation to count unique pages. With many pages per session, this can be expensive. **Mitigation:** If page_url cardinality is very high, consider pre-computing distinct page counts upstream.

### Full Table Scan Implications
- **No WHERE clause in final SELECT:** The entire `session_agg` CTE is scanned. If this table grows to billions of rows, incremental loads (e.g., only processing new events since last run) would be more efficient. **Recommendation:** Add a filter on `session_start >= DATEADD(day, -1, GETDATE())` if running daily, or implement incremental logic.

### Estimated Complexity
- **Input:** N events from `stg_raw_events`
- **Output:** M sessions (typically M << N, ratio depends on session length)
- **Time complexity:** O(N log N) due to sorting per user; O(N) for window functions and aggregation
- **Space complexity:** O(N) for intermediate CTEs

---

## Dependencies

### Upstream
- **staging.stg_raw_events** — Must be loaded and deduplicated before this transform runs. Typically populated by an ELT tool (e.g., Fivetran, Stitch) from web analytics platforms (e.g., Segment, Mixpanel) or custom event tracking systems.
  - **Assumed columns:** user_id, event_id, event_timestamp, event_type, page_url, referrer, device_type, country, event_revenue, session_id
  - **Assumed data quality:** No duplicate events; timestamps in UTC; user_id populated for all rows (or filtered upstream)

### Downstream
- **BI/Dashboard tools** (e.g., Tableau, Looker, Mode) — Query this table directly for session-level reporting, funnel analysis, and user journey visualization.
- **Attribution models** — Use first_touch_referrer and last_touch_referrer for multi-touch attribution calculations.
- **Customer segmentation pipelines** — Aggregate sessions per user to create cohorts (e.g., "high-value users," "at-risk users") based on session_outcome, session_revenue, and session_length_bucket.
- **Conversion funnel analysis** — Filter by session_outcome to analyze conversion rates and drop-off points.
- **Retention/churn models** — Use session_seq to compute time between sessions and predict churn.
- **Downstream transforms** (e.g., `fct_customer_lifetime_value`, `int_user_segments`) — Depend on this table as a base for user-level aggregations.

### External
- **None explicitly referenced.** However, the 30-minute session threshold and bucketing thresholds (10s, 2m, 10m) are industry conventions and should be validated against your product's analytics requirements.

---

## Maintenance & Monitoring Recommendations

1. **Data Quality Checks:**
   - Validate that `session_duration_sec >= 0` (no negative durations).
   - Validate that `session_end >= session_start`.
   - Monitor for unexpected spikes in `event_count` or `pages_viewed` (potential data quality issues upstream).
   - Alert if `user_id` nulls exceed a threshold (indicates tracking failures).

2. **Performance Monitoring:**
   - Track query execution time; if it exceeds SLA, consider incremental loading or materialized views.
   - Monitor table size growth; if it exceeds storage budget, implement retention policies (e.g., drop sessions older than 2 years).

3. **Business Logic Validation:**
   - Periodically review the 30-minute session threshold against actual user behavior (e.g., median time between events).
   - Validate session_outcome classifications against known conversion data to ensure accuracy.
   - Monitor first_touch vs. last_touch referrer distributions to detect attribution anomalies.

4. **Documentation Updates:**
   - If session threshold or bucketing thresholds change, update this documentation and notify downstream consumers.
   - If upstream schema changes (e.g., new event types, new attributes), assess impact on this transform.