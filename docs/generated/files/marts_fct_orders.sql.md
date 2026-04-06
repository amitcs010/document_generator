# marts/fct_orders.sql

## Component Overview
- **Layer:** Marts
- **Type:** Fact table (denormalized, aggregated)
- **Schedule:** Not specified in code; infer from dbt/orchestration config
- **Owner:** Not specified in code; likely BI/Analytics team lead

---

## Purpose

`fct_orders` is the primary order-level fact table consumed by BI tools and analysts. It combines order header data, line-item metrics, customer attributes, and session attribution into a single denormalized table optimized for reporting and analysis. This table serves as the single source of truth for order analytics, enabling dashboards, ad-hoc queries, and downstream ML models without requiring analysts to join multiple staging and intermediate tables.

---

## Inputs

| Source | Purpose | Criticality |
|--------|---------|-------------|
| **staging.stg_raw_orders** | Order header data: order ID, customer ID, order date/timestamp, status, channel, payment/shipping methods, amounts (shipping, tax, discount, total). This is the core order record. | CRITICAL |
| **staging.stg_raw_customers** | Customer attributes at time of order: loyalty tier, country, registration date. Used to enrich orders with customer lifecycle context. | HIGH |
| **transforms.int_order_items** | Line-item level data: product ID, category, quantity, revenue (gross/net), COGS, margin, discount flags. Aggregated to compute order-level metrics. | CRITICAL |
| **transforms.int_customer_sessions** | Session-level data: session ID, referrer, device type, session duration, pages viewed, purchase count. Used for last-click attribution within 24 hours of order. | MEDIUM |

---

## Outputs

| Target | Contents | Downstream Consumers |
|--------|----------|---------------------|
| **marts.fct_orders** | Denormalized order fact table with 50+ columns spanning order details, customer attributes, line-item metrics, attribution, and time dimensions. Grain: one row per order. | BI tools (Tableau, Looker), analytics team, finance reporting, customer success dashboards, ML feature engineering |

---

## Key Business Logic

### 1. **Order Metrics Aggregation** (CTE: `order_metrics`)
Aggregates line-item data from `int_order_items` to the order level:
- **Item count & product diversity:** `COUNT(*)`, `COUNT(DISTINCT product_id)`, `COUNT(DISTINCT category)` — enables analysis of order complexity and cross-category purchasing behavior.
- **Revenue & margin calculations:** `SUM(gross_revenue)`, `SUM(net_revenue)`, `SUM(total_cogs)`, `SUM(total_margin)`, `AVG(margin_pct)` — provides financial metrics for profitability analysis and margin trending.
- **Discount tracking:** `SUM(CASE WHEN is_discounted THEN 1 ELSE 0 END)` — counts discounted line items to identify promotional impact.
- **Category concatenation:** `LISTAGG(DISTINCT category, ', ')` — creates a human-readable list of categories purchased in a single order for segmentation and reporting.

**Why:** Analysts need order-level financial summaries without joining back to line items; this pre-aggregation improves query performance and simplifies downstream logic.

---

### 2. **Session Attribution** (CTE: `order_attribution`)
Performs last-click attribution by joining orders to the most recent session that occurred within 24 hours before the order:
- **Join logic:** `LEFT JOIN` on `customer_id = user_id`, `session_start <= order_timestamp`, `session_start >= DATEADD(hour, -24, order_timestamp)`, and `purchase_count > 0`.
- **Deduplication:** `ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY s.session_start DESC)` — ensures only the most recent qualifying session is selected (filtered to `_rn = 1` in final SELECT).
- **Attribution fields extracted:** `first_touch_referrer` (channel), `device_type`, `session_duration_sec`, `pages_viewed`.

**Why:** Marketing and product teams need to understand which channel/device drove each order. The 24-hour window balances attribution accuracy with session recency; sessions older than 24 hours are assumed not causal.

**Assumption:** A session with `purchase_count > 0` is assumed to be a converting session; if this flag is unreliable, attribution will be incorrect.

---

### 3. **Customer Lifecycle Segmentation**
Calculates `customer_tenure_days` and derives `customer_lifecycle_stage` using registration date:
```
New (0-30d) → Growing (31-90d) → Established (91-365d) → Loyal (365d+)
```

**Why:** Enables cohort analysis and retention studies; new customers often have different behavior and LTV than loyal customers.

---

### 4. **Order Flags (Boolean Indicators)**
Creates derived boolean columns for easy filtering and segmentation:
- `used_coupon` — TRUE if `coupon_code != 'NONE'`
- `has_discounted_items` — TRUE if any line items were discounted
- `is_refunded` — TRUE if `order_status = 'refunded'`
- `is_international` — TRUE if `shipping_country != billing_country`

**Why:** Enables quick filtering in BI tools without complex WHERE clauses; improves query readability and performance.

---

### 5. **Time Dimension Extraction**
Extracts temporal attributes from `order_date` and `order_timestamp`:
- `day_of_week`, `hour_of_day`, `order_month`, `week_of_year`

**Why:** Enables time-based analysis (e.g., "orders on weekends have higher AOV") without requiring analysts to compute these repeatedly.

---

### 6. **Filtering Logic**
Excludes orders with status `'pending_payment'` or `'fraud_review'`:
```sql
WHERE o.order_status NOT IN ('pending_payment', 'fraud_review')
```

**Why:** These orders are incomplete or under investigation; including them would skew revenue and customer metrics. Only finalized orders should be in the fact table.

---

### 7. **Null Handling**
- `NVL(a.attribution_channel, 'unknown')` — if no session found within 24 hours, defaults to 'unknown' rather than NULL.
- `LEFT JOIN` on customers and sessions — allows orders without matching customer or session records (e.g., guest checkout, missing session data).

**Why:** Prevents NULL values from breaking downstream aggregations; 'unknown' is explicit and queryable.

---

## Column Descriptions

| Column | Type | Description | Example |
|--------|------|-------------|---------|
| **order_id** | VARCHAR | Unique order identifier (primary key). | `ORD-2024-001234` |
| **customer_id** | VARCHAR | Foreign key to customer. | `CUST-5678` |
| **order_date** | DATE | Date the order was placed (no time component). | `2024-01-15` |
| **order_timestamp** | TIMESTAMP | Exact timestamp of order placement. | `2024-01-15 14:32:45` |
| **order_status** | VARCHAR | Current status of the order. | `completed`, `shipped`, `refunded` |
| **order_channel** | VARCHAR | Channel through which order was placed. | `web`, `mobile_app`, `phone` |
| **customer_lifecycle_stage** | VARCHAR | Derived customer tenure bucket. | `New (0-30d)`, `Loyal (365d+)` |
| **gross_revenue** | DECIMAL(18,2) | Total revenue before discounts and returns. | `149.99` |
| **net_revenue** | DECIMAL(18,2) | Revenue after discounts and returns. | `119.99` |
| **total_margin** | DECIMAL(18,2) | Gross profit (net revenue - COGS). | `45.00` |
| **attribution_channel** | VARCHAR | Marketing channel of converting session (last-click). | `organic_search`, `paid_social`, `direct`, `unknown` |
| **conversion_device** | VARCHAR | Device type used in converting session. | `desktop`, `mobile`, `tablet`, `unknown` |
| **item_count** | INT | Number of line items in the order. | `3` |
| **unique_products** | INT | Number of distinct products ordered. | `2` |
| **is_international** | BOOLEAN | TRUE if shipping and billing countries differ. | `true`, `false` |
| **_loaded_at** | TIMESTAMP | Timestamp when this row was inserted (SCD Type 2 marker). | `2024-01-16 02:15:30` |

---

## Data Quality & Edge Cases

### Null Handling
- **Attribution fields:** If no session exists within 24 hours, `attribution_channel` and `conversion_device` default to `'unknown'` (not NULL). This ensures every order has a channel value for grouping.
- **Customer data:** If a customer record is missing (e.g., guest checkout), `loyalty_tier` and `customer_since` will be NULL. Queries must account for this.
- **Session data:** If session lookup fails, all session-related columns (`converting_session_id`, `conversion_session_duration`, `pre_purchase_pages`) will be NULL.

### Deduplication Strategy
- **Order metrics:** Grouped by `order_id` — one row per order guaranteed.
- **Session attribution:** `ROW_NUMBER()` ensures only the most recent session within 24 hours is selected. If multiple sessions exist in the same hour, the one with the latest `session_start` wins.
- **No deduplication on orders themselves:** If `stg_raw_orders` contains duplicate order records, they will appear as duplicate rows in `fct_orders`. **This is a risk.**

### Key Assumptions
1. **`int_order_items.is_discounted` is accurate:** If this flag is unreliable, `discounted_items` count will be wrong.
2. **`int_customer_sessions.purchase_count > 0` indicates a converting session:** If this flag is noisy or incorrectly populated, attribution will be inaccurate.
3. **24-hour attribution window is appropriate:** If the actual customer journey spans >24 hours, true attribution will be missed.
4. **`stg_raw_orders` has no duplicates:** If source data contains duplicate order records, they will propagate to the mart.
5. **`order_status` values are consistent:** If status values change or are misspelled, the WHERE clause filter may not work as intended.
6. **Customer registration date is immutable:** If `registration_date` is updated retroactively, `customer_tenure_days` calculations will be incorrect.

### What Could Break
- **Upstream schema changes:** If `int_order_items` removes the `is_discounted` column, the query fails.
- **Null explosion in `int_customer_sessions`:** If session data becomes sparse, many orders will have `attribution_channel = 'unknown'`, reducing attribution accuracy.
- **Duplicate orders in source:** If `stg_raw_orders` is not deduplicated, fact table will contain duplicates.
- **Session timestamp drift:** If `session_start` is recorded in a different timezone than `order_timestamp`, the 24-hour join window may be off.
- **Coupon code format change:** If `coupon_code` is no longer `'NONE'` for non-coupon orders, the `used_coupon` flag will be incorrect.

---

## Performance Notes

### Join Strategy & Implications

| Join | Type | Cardinality | Performance Impact |
|------|------|-------------|-------------------|
| `order_metrics` (CTE) | INNER | 1:1 (order to aggregated metrics) | **Fast.** Pre-aggregation in CTE avoids repeated line-item scans. |
| `stg_raw_customers` | LEFT | 1:1 (order to customer) | **Fast.** Lookup on `customer_id`; assumes customer table is indexed. |
| `order_attribution` (CTE) | LEFT | 1:1 (order to most recent session) | **Moderate risk.** The subquery joins orders to sessions with a time-range condition (`session_start <= order_timestamp AND session_start >= DATEADD(hour, -24, order_timestamp)`). If `int_customer_sessions` is large and lacks proper indexing on `user_id` and `session_start`, this could scan many rows. |

### Expensive Operations
1. **`LISTAGG(DISTINCT category, ', ')` in `order_metrics` CTE:** String aggregation can be slow on large result sets. If an order has 100+ line items, this becomes expensive. Consider capping or removing if not needed.
2. **`ROW_NUMBER()` window function in `order_attribution`:** Requires sorting sessions by `session_start DESC` per order. If there are many sessions per customer, this is expensive.
3. **`DATEDIFF()` calculations for tenure:** Computed for every row; not cached. If used in WHERE clauses downstream, consider pre-computing in a separate dimension table.

### Partitioning & Distribution Keys
```sql
DISTKEY(order_id)
SORTKEY(order_date)
```

- **DISTKEY(order_id):** Distributes rows across Redshift nodes by order ID. This is appropriate if downstream queries often filter by order ID or join on it. However, if queries typically group by `order_date` or `customer_id`, this may cause skew.
- **SORTKEY(order_date):** Sorts rows by order date within each node. Ideal for time-series queries (e.g., "orders by month"). However, if queries frequently filter by `customer_id` or `attribution_channel`, a different sort key might be better.

**Recommendation:** Consider a compound sort key like `SORTKEY(order_date, customer_id)` if both time and customer analysis are common.

### Full Table Scans
- The final SELECT scans all of `stg_raw_orders` (filtered by status). If this table is very large, consider adding a date range filter or incremental loading strategy.

### Materialization Strategy
- **DROP TABLE IF EXISTS + CREATE TABLE AS:** This is a full refresh. Every time the job runs, the entire table is rebuilt. This is safe but slow for large tables. Consider switching to incremental logic (INSERT/UPDATE) if the table grows beyond 1B rows.

---

## Dependencies

### Upstream (Must Run Before This Component)
1. **staging.stg_raw_orders** — Raw order data must be loaded and cleaned.
2. **staging.stg_raw_customers** — Raw customer data must be available.
3. **transforms.int_order_items** — Line-item aggregation must be computed (depends on raw order items).
4. **transforms.int_customer_sessions** — Session data must be transformed and aggregated.

**Dependency Chain:**
```
raw_orders → stg_raw_orders ─┐
raw_customers → stg_raw_customers ─┤
raw_order_items → int_order_items ─┼→ fct_orders
raw_sessions → int_customer_sessions ─┘
```

### Downstream (Depends on This Component)
- **BI dashboards** (Tableau, Looker, Power BI) — Primary consumer; queries `fct_orders` for order metrics, customer segmentation, attribution analysis.
- **Finance reporting** — Uses `fct_orders` for revenue, margin, and discount analysis.
- **Customer success dashboards** — Queries for customer lifecycle and order history.
- **ML feature engineering** — Derives features from `fct_orders` for churn prediction, LTV models, etc.
- **Ad-hoc analyst queries** — General-purpose analytics and exploratory analysis.

### External Dependencies
- **Redshift cluster:** Requires Redshift to be running and accessible.
- **IAM permissions:** `analytics_readers` and `bi_team` groups must exist and have SELECT grants.
- **Orchestration tool** (dbt, Airflow, etc.): Not visible in code but required to schedule and run this SQL.

---

## Additional Notes

### Maintenance & Monitoring
- **Monitor row count:** Track `SELECT COUNT(*) FROM marts.fct_orders` over time. Sudden drops may indicate upstream data issues.
- **Monitor NULL rates:** Check `SELECT COUNT(*) WHERE attribution_channel = 'unknown'` to detect session attribution failures.
- **Monitor duplicate orders:** Run `SELECT order_id, COUNT(*) FROM marts.fct_orders GROUP BY order_id HAVING COUNT(*) > 1` to detect duplicates from upstream.
- **Analyze table regularly:** The `ANALYZE` command at the end updates table statistics for the query planner. Ensure this runs after every load.

### Future Improvements
1. **Incremental loading:** Replace full refresh with INSERT/UPDATE logic to improve performance on large tables.
2. **Separate dimension tables:** Extract `customer_lifecycle_stage` and time dimensions into separate dimension tables to reduce denormalization and improve maintainability.
3. **SCD Type 2 tracking:** Add `_valid_from` and `_valid_to` columns to track customer attribute changes over time.
4. **Materialized session attribution:** Pre-compute session-to-order mappings in a separate table to avoid expensive window functions.
5. **Configurable attribution window:** Make the 24-hour window a parameter rather than hardcoded.