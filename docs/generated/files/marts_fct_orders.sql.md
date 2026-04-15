# marts/fct_orders.sql

## Component Overview
- **Layer:** Marts
- **Type:** Fact table (denormalized, aggregated)
- **Schedule:** Not specified in code; infer from dbt/orchestration config
- **Owner:** Not specified in code; likely BI/Analytics team based on grants

---

## Purpose

`fct_orders` is the primary order-level fact table consumed by BI tools and analysts. It combines order header data, line-item metrics, customer attributes, and session attribution into a single denormalized table optimized for reporting and ad-hoc analysis. This table serves as the single source of truth for order analytics, enabling stakeholders to analyze order value, customer behavior, product mix, and marketing attribution without requiring complex joins.

---

## Inputs

| Source Table | Purpose | Data Provided |
|---|---|---|
| **staging.stg_raw_orders** | Order header records | Order ID, customer ID, order date/timestamp, status, channel, payment/shipping methods, amounts (shipping, tax, discount, total), billing/shipping addresses, coupon codes |
| **staging.stg_raw_customers** | Customer master data | Customer ID, loyalty tier, country, registration date (used to calculate tenure and lifecycle stage) |
| **transforms.int_order_items** | Order line-item details | Product ID, category, quantity, revenue (gross/net), COGS, margin calculations, discount flags (aggregated to order level) |
| **transforms.int_customer_sessions** | Web session data | Session ID, user ID, session start/end, referrer, device type, session duration, pages viewed, purchase count (filtered to last session within 24 hours before order) |

---

## Outputs

| Target Table | Contents | Downstream Consumers |
|---|---|---|
| **marts.fct_orders** | Denormalized order fact table with ~40 columns including order metrics, customer attributes, attribution, and time dimensions | BI tools (Tableau, Looker, etc.), analytics team, executive dashboards, revenue reporting, customer segmentation analysis |

---

## Key Business Logic

### 1. **Order-Level Aggregation (order_metrics CTE)**
Aggregates line-item data from `int_order_items` to the order level:
- **Item count & product diversity:** `COUNT(*)`, `COUNT(DISTINCT product_id)`, `COUNT(DISTINCT category)` — enables analysis of order complexity and cross-category purchasing behavior
- **Revenue metrics:** `SUM(gross_revenue)`, `SUM(net_revenue)` — gross is pre-discount, net is post-discount; both needed for margin analysis
- **Margin calculations:** `SUM(gross_margin)`, `ROUND(AVG(margin_pct), 2)` — average margin % rounded to 2 decimals for reporting consistency
- **Discount tracking:** `SUM(CASE WHEN is_discounted THEN 1 ELSE 0 END)` — counts line items with discounts to identify heavily discounted orders
- **Category list:** `LISTAGG(DISTINCT category, ', ')` — human-readable list of all categories in order for quick analysis

### 2. **Session Attribution (order_attribution CTE)**
Identifies the converting session (last session before purchase within 24 hours):
- **Time window:** `s.session_start <= o.order_timestamp AND s.session_start >= DATEADD(hour, -24, o.order_timestamp)` — restricts to sessions within 24 hours before order; assumes purchase intent forms within this window
- **Purchase-qualified sessions:** `s.purchase_count > 0` — filters to sessions where user made a purchase, reducing noise from browsing sessions
- **Last-touch attribution:** `ROW_NUMBER() OVER (PARTITION BY o.order_id ORDER BY s.session_start DESC)` — implements last-touch attribution model; most recent session before purchase is assumed to be the converting session
- **Deduplication:** `WHERE a._rn = 1` in final SELECT ensures only one session per order

**Business assumption:** Last session before purchase is the primary driver; earlier sessions are ignored. This is a simplified model; multi-touch attribution would require different logic.

### 3. **Customer Lifecycle Segmentation**
Calculates tenure and assigns lifecycle stage based on days since registration:
```
New (0-30d) → Growing (31-90d) → Established (91-365d) → Loyal (365d+)
```
**Purpose:** Enables cohort analysis and retention tracking; new customers often have different behavior/profitability than loyal customers.

### 4. **Order Flags (Boolean Indicators)**
Derived flags for easy filtering in BI tools:
- `used_coupon` — TRUE if coupon_code != 'NONE'
- `has_discounted_items` — TRUE if any line item was discounted
- `is_refunded` — TRUE if order_status = 'refunded'
- `is_international` — TRUE if shipping_country != billing_country

### 5. **Status Filtering**
```sql
WHERE o.order_status NOT IN ('pending_payment', 'fraud_review')
```
**Rationale:** Excludes incomplete/disputed orders from fact table. These orders lack final financial data and would skew revenue metrics. Typically handled separately in a staging/investigation table.

### 6. **Time Dimensions**
Extracts temporal attributes for time-series analysis:
- `day_of_week`, `hour_of_day`, `week_of_year`, `order_month` — enables day-of-week/hour-of-day patterns, weekly trends, monthly reporting

---

## Column Descriptions

| Column | Data Type | Description | Example Values |
|---|---|---|---|
| **order_id** | INT | Unique order identifier; primary key | 1001, 1002, 1003 |
| **customer_id** | INT | Foreign key to customer; used for joins and segmentation | 501, 502, 503 |
| **order_date** | DATE | Date order was placed (date component only) | 2024-01-15 |
| **order_timestamp** | TIMESTAMP | Full timestamp of order placement; used for session attribution | 2024-01-15 14:32:45 |
| **order_status** | VARCHAR | Final order status; filtered to exclude pending/fraud | 'completed', 'shipped', 'refunded' |
| **order_channel** | VARCHAR | Channel through which order was placed | 'web', 'mobile_app', 'phone' |
| **gross_revenue** | DECIMAL(12,2) | Total revenue before discounts; used for top-line metrics | 149.99, 500.00 |
| **net_revenue** | DECIMAL(12,2) | Revenue after line-item discounts; used for actual revenue reporting | 119.99, 450.00 |
| **total_margin** | DECIMAL(12,2) | Gross profit (net_revenue - COGS); key profitability metric | 45.00, 150.00 |
| **avg_margin_pct** | DECIMAL(5,2) | Average margin percentage across line items; rounded to 2 decimals | 30.00, 45.50 |
| **customer_lifecycle_stage** | VARCHAR | Derived customer tenure bucket; enables cohort analysis | 'New (0-30d)', 'Loyal (365d+)' |
| **attribution_channel** | VARCHAR | First-touch referrer from converting session; NVL to 'unknown' if no session found | 'organic_search', 'paid_social', 'direct', 'unknown' |
| **converting_session_id** | INT | Session ID of last session before purchase; NULL if no qualifying session | 9001, 9002, NULL |
| **is_international** | BOOLEAN | TRUE if shipping country differs from billing country | TRUE, FALSE |
| **_loaded_at** | TIMESTAMP | Load timestamp; tracks when row was inserted | 2024-01-16 02:15:30 |

---

## Data Quality & Edge Cases

### Null Handling
| Scenario | Handling | Rationale |
|---|---|---|
| Customer not found in `stg_raw_customers` | LEFT JOIN; customer attributes become NULL | Orphaned orders can occur; don't fail the load |
| No qualifying session within 24 hours | LEFT JOIN + `NVL(a.attribution_channel, 'unknown')` | Not all orders have trackable sessions (e.g., phone orders, returning customers); 'unknown' is explicit marker |
| Coupon code missing or 'NONE' | `used_coupon = FALSE` | Treats missing/NONE as no coupon; consistent with business logic |
| Order status is NULL | Excluded by WHERE clause (NULL NOT IN (...) is FALSE in SQL) | Rare but possible; safer to exclude than include |

### Deduplication Strategy
- **Order level:** One row per order_id (INNER JOIN on order_metrics ensures only orders with line items)
- **Session attribution:** `ROW_NUMBER() OVER (...) = 1` ensures only the most recent session per order is retained
- **No duplicate orders:** Assumes `stg_raw_orders` has unique order_id; if duplicates exist upstream, this table will inherit them

### Key Assumptions
1. **Session data is clean:** Assumes `int_customer_sessions` has no duplicate sessions per user per timestamp
2. **Order items always exist:** INNER JOIN on `order_metrics` means orders without line items are excluded (typically correct, but could hide data issues)
3. **Customer registration date is immutable:** Uses registration_date to calculate tenure; if this changes upstream, tenure recalculates retroactively
4. **24-hour attribution window is appropriate:** Hard-coded window may not fit all business models (e.g., high-consideration products may need longer window)
5. **Last-touch attribution is the model:** No multi-touch or first-touch attribution; if business needs change, CTE logic must be rewritten
6. **Order status values are consistent:** Assumes status values like 'pending_payment', 'fraud_review', 'completed' are standardized upstream

### What Could Break
- **Upstream schema changes:** If `int_order_items` removes `is_discounted` or `margin_pct`, aggregations fail
- **Session data quality degradation:** If `int_customer_sessions.purchase_count` becomes unreliable, attribution becomes noisy
- **Customer ID mismatches:** If `stg_raw_orders.customer_id` references non-existent customers in `stg_raw_customers`, LEFT JOIN silently produces NULLs (may be undetected)
- **Timestamp inconsistencies:** If `order_timestamp` and `session_start` are in different timezones, 24-hour window logic breaks
- **Status value changes:** If new status values are introduced (e.g., 'cancelled'), they are included in fact table; may need WHERE clause update
- **Coupon code format changes:** If 'NONE' is replaced with NULL or empty string, `used_coupon` logic breaks

---

## Performance Notes

### Join Strategies & Implications

| Join | Type | Implication |
|---|---|---|
| `stg_raw_orders` → `order_metrics` | INNER | Filters to orders with line items; fast if `order_metrics` CTE is indexed/materialized |
| `stg_raw_orders` → `stg_raw_customers` | LEFT | Preserves all orders; slower if customer table is large (no filter on customer_id in join condition) |
| `stg_raw_orders` → `int_customer_sessions` | LEFT | Expensive: joins on customer_id + timestamp range (`session_start <= order_timestamp AND session_start >= DATEADD(hour, -24, ...)`) — range join is not sargable; may require full scan of sessions table |

### Distribution & Sort Keys
```sql
DISTKEY(order_id)
SORTKEY(order_date)
```
- **DISTKEY(order_id):** Distributes rows across nodes by order_id; ensures order_metrics CTE joins efficiently (co-located on same node)
- **SORTKEY(order_date):** Sorts by order_date; optimizes time-series queries (e.g., "orders by month") and range scans on date
- **Implication:** Queries filtering on order_date or joining on order_id will be fast; queries on customer_id or attribution_channel will require redistribution

### Expensive Operations
1. **Range join in order_attribution CTE:** The condition `s.session_start >= DATEADD(hour, -24, o.order_timestamp)` is a range predicate; Redshift may not optimize this well. Consider:
   - Pre-filtering sessions to last 24 hours in `int_customer_sessions` materialization
   - Using a date-based join key (e.g., session_date = order_date) if sessions are typically same-day
2. **LISTAGG with DISTINCT:** `LISTAGG(DISTINCT category, ', ')` requires sorting and deduplication; can be slow if orders have many categories
3. **Full table scan on int_customer_sessions:** If sessions table is not indexed on (user_id, session_start), the LEFT JOIN may scan entire table

### Materialization & Refresh
- **Table type:** Materialized table (CREATE TABLE AS), not a view; data is static until next refresh
- **Refresh frequency:** Not specified in code; typically daily or hourly depending on BI SLA
- **Incremental vs. full refresh:** Code uses DROP TABLE + CREATE TABLE (full refresh); consider incremental upsert if table grows large (millions of rows)

---

## Dependencies

### Upstream (Must Run Before This Component)
1. **staging.stg_raw_orders** — Raw order data from source system; must be loaded first
2. **staging.stg_raw_customers** — Raw customer master; must be loaded first
3. **transforms.int_order_items** — Transformed line-item data with margin calculations; must be materialized before aggregation
4. **transforms.int_customer_sessions** — Transformed session data with purchase_count; must be materialized before attribution join

**Dependency chain:** Raw data → Staging → Transforms → Marts

### Downstream (Components That Depend on This Output)
- **BI dashboards:** Tableau, Looker, Power BI dashboards query `fct_orders` directly
- **Analytics reports:** Revenue reports, customer segmentation, cohort analysis
- **Data science models:** Customer lifetime value (CLV), churn prediction, product recommendation models
- **Executive dashboards:** KPI tracking (AOV, conversion rate, margin %)
- **Potentially:** Other mart tables (e.g., `fct_customer_orders` or `fct_revenue`) may join or reference this table

### External Dependencies
- **Redshift cluster:** Code is Redshift-specific (uses `DISTKEY`, `SORTKEY`, `GETDATE()`, `DATE_PART()`, `LISTAGG()`, `DATEADD()`)
- **IAM/Permissions:** Grants to `analytics_readers` and `bi_team` groups; assumes these groups exist in Redshift
- **Orchestration tool:** dbt, Airflow, or similar must schedule this job; no schedule specified in code

---

## Additional Notes

### Maintenance & Monitoring
- **ANALYZE statement:** `ANALYZE marts.fct_orders;` at end updates table statistics for query optimizer; critical for performance
- **Row count tracking:** Monitor row count over time; sudden drops may indicate upstream data issues
- **NULL rates:** Monitor NULL rates in `converting_session_id` and `attribution_channel`; high rates may indicate session data quality issues

### Future Enhancements
1. **Incremental refresh:** Replace DROP/CREATE with UPSERT to handle large tables efficiently
2. **Multi-touch attribution:** Extend `order_attribution` CTE to include all sessions (not just last) for more sophisticated attribution models
3. **Slowly Changing Dimensions (SCD):** Customer attributes (loyalty_tier, country) may change; current design captures point-in-time snapshot; consider SCD Type 2 if historical tracking needed
4. **Partitioning:** If table grows beyond 1B rows, consider partitioning by `order_month` or `order_date` for faster queries and maintenance