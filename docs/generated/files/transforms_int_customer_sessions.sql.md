# transforms.int_customer_sessions

**Purpose**
Transforms raw clickstream events into sessionized customer activity records. Detects session boundaries based on 30-minute inactivity gaps, aggregates event-level metrics (purchases, cart additions, pages viewed), computes session duration, and assigns first/last touch attribution for marketing analysis.

**Inputs**
- `staging.stg_raw_events` – Raw event records with user_id, event_timestamp, event_type, page_url, referrer, device_type, country, event_revenue

**Outputs**
- `transforms.int_customer_sessions` – One row per user session with aggregated metrics and attribution fields

**Key Transformations**
1. **Session Detection** – Identifies new sessions when event gap exceeds 30 minutes or is first event per user
2. **Session Aggregation** – Groups events by user and session; computes counts, duration, revenue, and distinct pages
3. **Attribution** – Captures first/last touch referrer and device type using window functions
4. **Session Classification** – Assigns outcome (converted/engaged/browsing/bounced) and duration bucket (bounce/short/medium/long)
5. **Metadata** – Adds load timestamp and filters null user_ids

**Dependencies**
- Upstream: `staging.stg_raw_events`
- Downstream: Analytics queries, BI tools (via `analytics_readers` group grant)
- Distribution: DISTKEY on user_id; SORTKEY on session_start for query optimization

**Notes**
- 30-minute session timeout is hardcoded; consider parameterizing for flexibility
- ANALYZE command updates table statistics post-load
- Assumes session_id exists in source; verify if it's a generated or source field
- Window functions compute first/last touch across full session range; ensure event_timestamp ordering is reliable