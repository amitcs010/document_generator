# marts/fct_orders.sql

## Component Overview
- **Layer:** Marts
- **Type:** Fact table (denormalized, aggregated)
- **Schedule:** Not specified in code; infer from dbt/orchestration config
- **Owner:** Not specified in code; likely BI/Analytics team based on grants

---

## Purpose

`fct_orders` is the primary order-level fact table consumed by BI tools and analysts. It combines order header data, line-item metrics, customer attributes, and session attribution into a single denormalized table optimized for reporting and ad-hoc analysis. This table serves as the source of truth for order analytics, enabling dashboards, KPI tracking, and customer segmentation across the organization.

---

## Inputs

| Source Table | Purpose | Data Provided |
|---|---|---|
| **staging.stg_raw_orders** | Order header records | Order ID, customer ID, order date/timestamp, status, channel, payment/shipping methods, amounts (gross, tax, discount), coupon codes, and country information. This is the primary order dimension. |
| **staging.stg_raw_customers** | Customer master data | Customer ID, loyalty tier, country, registration date. Provides customer context at the time of order (used for tenure calculations and lifecycle segmentation). |
| **transforms.int_order_items** | Line-item aggregations | Pre-aggregated metrics per order: item count, unique products/categories, quantities, revenue (gross/net), COGS, margins, and discount flags. Eliminates need to join raw line items. |
| **transforms.int_customer_sessions** | Session-level attribution | Session ID, referrer channel, device type, session duration, pages viewed, and purchase indicators. Used to attribute orders to the converting session within a 24-hour lookback window. |

---

## Outputs

| Target Table | Contents | Downstream Consumers |
|---|---|---|
| **marts.fct_orders** | Denormalized order fact table with 50+ columns including order details, customer attributes, line-item metrics, attribution, and time dimensions. One row per order. | BI tools (Tableau, Looker, Power BI), analytics team, executive dashboards, customer segmentation models, revenue reporting, cohort analysis. |

---

## Key Business Logic

### 1. **Order Metrics Aggregation** (CTE: `order_metrics`)
Aggregates line-item data from `int_order_items` to the order level:
- **Item & Product Counts:** Captures breadth of order (how many SKUs, categories purchased). Used for basket analysis and cross-sell metrics.
- **Revenue & Margin Calculations:** Sums gross revenue, net revenue, COGS, and gross margin across all line items. Enables profitability analysis at order level.
- **Discount Tracking:** Counts discounted line items separately. Allows filtering/segmentation of promotional vs. full-price orders.
- **Category List:** Uses `LISTAGG` to create a human-readable string of categories purchased (e.g., "Electronics, Home & Garden"). Enables quick visual inspection and category-based filtering in BI tools.

**Why aggregated here:** Avoids expensive joins to raw line items in downstream queries; improves BI tool performance.

---

### 2. **Session Attribution** (CTE: `order_attribution`)
Identifies the converting session for each order using a 24-hour lookback window:
- **Join Logic:** Left joins `int_customer_sessions` to `stg_raw_orders` on customer ID, filtering sessions that:
  - Occurred **before or at** the order timestamp (`session_start <= order_timestamp`)
  - Occurred **within 24 hours before** the order (`session_start >= DATEADD(hour, -24, order_timestamp)`)
  - Had at least one purchase event (`purchase_count > 0`)
- **Deduplication:** `ROW_NUMBER()` partitioned by order ID, ordered by session start descending, selects the **most recent qualifying session** (last-click attribution model).

**Why this logic:** Assumes the last session before purchase is most relevant for attribution. 24-hour window balances recency with reasonable session-to-order lag. `purchase_count > 0` filters for sessions with purchase intent signals.

**Edge case:** If no qualifying session exists, attribution columns are `NULL` and coalesced to `'unknown'` in the final SELECT.

---

### 3. **Customer Lifecycle Segmentation**
Calculates `customer_tenure_days` and derives `customer_lifecycle_stage` based on days since registration:
- **New (0-30d):** First month customers; high churn risk, high engagement potential.
- **Growing (31-90d):** Early repeat customers; critical retention window.
- **Established (91-365d):** Maturing customers; building loyalty.
- **Loyal (365d+):** Long-term customers; highest LTV.

**Why:** Enables cohort-based analysis, retention tracking, and lifecycle-specific marketing strategies.

---

### 4. **Order Flags (Boolean Dimensions)**
Creates binary indicators for common filtering/segmentation:
- `used_coupon`: TRUE if coupon code is not 'NONE'. Identifies promotional vs. organic orders.
- `has_discounted_items`: TRUE if any line item was discounted. Distinguishes order-level discounts from item-level.
- `is_refunded`: TRUE if order status is 'refunded'. Flags problematic orders.
- `is_international`: TRUE if shipping country differs from billing country. Identifies cross-border orders (higher complexity/cost).

**Why:** Simplifies BI filtering; avoids repeated CASE logic in downstream queries.

---

### 5. **Time Dimensions**
Extracts temporal attributes for time-series analysis and grouping:
- `day_of_week` (0-6): Enables day-of-week seasonality analysis.
- `hour_of_day` (0-23): Identifies peak ordering times.
- `order_month` (YYYY-MM): Standard month grouping for trend analysis.
- `week_of_year` (1-52): Week-level aggregation for weekly reporting.

**Why:** Pre-computed to avoid repeated extraction in BI tools; improves query performance.

---

### 6. **Filtering Logic**
Excludes orders with status `'pending_payment'` or `'fraud_review'`:
```sql
WHERE o.order_status NOT IN ('pending_payment', 'fraud_review')
```

**Why:** These orders are incomplete or under investigation; including them would skew revenue/conversion metrics. Only settled, completed, or refunded orders are included.

---

## Column Descriptions

| Column Name | Data Type | Description | Example Values |
|---|---|---|---|
| **order_id** | INT | Unique order identifier; primary key. | 1001, 1002, 1003 |
| **customer_id** | INT | Foreign key to customer; enables customer-level joins. | 501, 502, 503 |
| **order_date** | DATE | Date order was placed (no time component). | 2024-01-15 |
| **order_timestamp** | TIMESTAMP | Precise timestamp of order placement; used for session attribution. | 2024-01-15 14:32:45 |
| **order_status** | VARCHAR | Current order state. | 'completed', 'shipped', 'refunded' |
| **order_channel** | VARCHAR | Sales channel through which order was placed. | 'web', 'mobile_app', 'in_store' |
| **gross_revenue** | DECIMAL(12,2) | Total revenue before discounts/returns; sum of line-item gross revenue. | 150.00, 2500.50 |
| **net_revenue** | DECIMAL(12,2) | Revenue after discounts; sum of line-item net revenue. | 135.00, 2250.50 |
| **total_margin** | DECIMAL(12,2) | Gross profit (net revenue - COGS); sum of line-item margins. | 45.00, 750.00 |
| **avg_margin_pct** | DECIMAL(5,2) | Average margin percentage across line items; rounded to 2 decimals. | 33.33, 45.67 |
| **customer_lifecycle_stage** | VARCHAR | Derived customer tenure segment. | 'New (0-30d)', 'Loyal (365d+)' |
| **attribution_channel** | VARCHAR | First-touch referrer of converting session (last-click attribution). | 'organic_search', 'paid_social', 'direct', 'unknown' |
| **conversion_device** | VARCHAR | Device type used in converting session. | 'desktop', 'mobile', 'tablet', 'unknown' |
| **item_count** | INT | Number of line items in order. | 1, 5, 12 |
| **total_units** | INT | Total quantity of units ordered (sum across line items). | 3, 25, 100 |
| **is_international** | BOOLEAN | TRUE if shipping country ≠ billing country. | TRUE, FALSE |
| **_loaded_at** | TIMESTAMP | Timestamp when row was inserted into table; audit column. | 2024-01-20 08:15:30 |

---

## Data Quality & Edge Cases

### Null Handling

| Scenario | Column(s) Affected | Handling | Impact |
|---|---|---|---|
| **No matching customer record** | `loyalty_tier`, `customer_country`, `customer_since`, `customer_tenure_days`, `customer_lifecycle_stage` | LEFT JOIN allows NULLs; no coalescing. | Rows with missing customer data still appear; analysts must filter `WHERE customer_id IS NOT NULL` if needed. |
| **No qualifying session within 24h** | `attribution_channel`, `conversion_device`, `converting_session_id`, `conversion_session_duration`, `pre_purchase_pages` | LEFT JOIN allows NULLs; then coalesced to `'unknown'` for channel/device. | Attribution defaults to 'unknown'; session metrics remain NULL. Indicates direct/organic traffic or session data gaps. |
| **Coupon code missing or 'NONE'** | `coupon_code`, `used_coupon` | `coupon_code` stored as-is; `used_coupon` = FALSE if 'NONE'. | Distinguishes non-promotional orders; safe for filtering. |
| **Refunded orders** | `order_status`, `is_refunded` | Included in table (not filtered out); flagged with `is_refunded = TRUE`. | Analysts must exclude refunds when calculating revenue KPIs; flag enables easy filtering. |

### Deduplication Strategy

- **Order Level:** One row per `order_id` (enforced by INNER JOIN to `order_metrics` which groups by `order_id`).
- **Session Attribution:** `ROW_NUMBER()` with `ORDER BY session_start DESC` ensures only the **most recent session** within 24h is selected (last-click model). Ties broken by session start time.
- **Customer Attributes:** One customer record per `customer_id` in `stg_raw_customers`; no deduplication needed (assumed clean upstream).

### Assumptions About Upstream Data

1. **`stg_raw_orders` is unique on `order_id`:** No duplicate order records.
2. **`int_order_items` is pre-aggregated:** Already grouped by `order_id`; no need to re-aggregate line items.
3. **`int_customer_sessions` has valid `session_start` timestamps:** Used for 24-hour lookback; malformed timestamps would break attribution.
4. **Customer registration dates are accurate:** Used for tenure calculation; future dates or NULLs would cause incorrect lifecycle segmentation.
5. **Order status values are standardized:** Filtering on `'pending_payment'` and `'fraud_review'` assumes these exact strings exist upstream.
6. **Coupon codes are either valid strings or 'NONE':** No other null/placeholder values expected.

### What Could Break

| Risk | Cause | Impact | Mitigation |
|---|---|---|---|
| **Duplicate orders in fact table** | `stg_raw_orders` contains duplicate `order_id` values. | Revenue metrics inflated; row counts incorrect. | Add `DISTINCT` to `stg_raw_orders` join or validate upstream uniqueness. |
| **Missing line-item aggregations** | `int_order_items` missing an order that exists in `stg_raw_orders`. | INNER JOIN causes order to be dropped silently. | Change to LEFT JOIN and handle NULLs, or validate completeness upstream. |
| **Session attribution logic breaks** | `int_customer_sessions.session_start` contains NULLs or invalid timestamps. | Attribution join fails or produces incorrect results. | Add NOT NULL constraint upstream; validate timestamp format. |
| **Lifecycle segmentation incorrect** | `stg_raw_customers.registration_date` contains future dates or NULLs. | Tenure calculation negative or NULL; lifecycle stage incorrect. | Add data quality checks upstream; handle NULLs with COALESCE. |
| **Refunded orders excluded unintentionally** | Status values change (e.g., 'refunded' → 'returned'). | Revenue metrics exclude legitimate refunds; incomplete picture. | Maintain status value mapping; document expected values. |

---

## Performance Notes

### Join Strategies & Implications

| Join | Type | Cardinality | Performance Impact | Notes |
|---|---|---|---|---|
| **order_metrics → stg_raw_orders** | INNER | 1:1 (order_id) | Fast; small result set. | Aggregation in CTE reduces rows before main join. |
| **stg_raw_customers → stg_raw_orders** | LEFT | N:1 (customer_id) | Fast; customer table typically small. | LEFT JOIN preserves orders with missing customer data. |
| **order_attribution → stg_raw_orders** | LEFT | 1:1 (order_id, _rn=1) | Moderate; depends on session table size. | Window function deduplication ensures 1:1 cardinality. 24-hour filter reduces session scan scope. |

### Expensive Operations

1. **`LISTAGG(DISTINCT category, ', ')` in `order_metrics` CTE:**
   - Aggregates all categories per order into a single string.
   - **Cost:** O(n) per order; can be slow if orders have many line items.
   - **Mitigation:** Used only for readability; consider removing if not needed in BI tools.

2. **`ROW_NUMBER()` window function in `order_attribution` CTE:**
   - Partitions sessions by order_id and ranks by session_start.
   - **Cost:** O(n log n) for large session tables; requires sort.
   - **Mitigation:** 24-hour filter (`session_start >= DATEADD(hour, -24, ...)`) reduces input size.

3. **LEFT JOIN to `int_customer_sessions` with multi-condition filter:**
   - Joins on customer_id + timestamp range + purchase_count.
   - **Cost:** Full table scan of sessions if no index on (user_id, session_start).
   - **Mitigation:** Ensure `int_customer_sessions` is indexed on (user_id, session_start); consider pre-filtering sessions in upstream transform.

### Partitioning & Distribution Keys

```sql
DISTKEY(order_id)
SORTKEY(order_date)
```

- **DISTKEY(order_id):** Distributes rows across Redshift nodes by order_id. Ensures orders are co-located for joins on order_id (e.g., with line items). Reduces network traffic.
- **SORTKEY(order_date):** Sorts rows within each node by order_date. Optimizes range scans on date (e.g., "orders in last 30 days"). Improves compression.

**Why these choices:**
- Most BI queries filter/group by date range; SORTKEY on `order_date` enables efficient range scans.
- DISTKEY on `order_id` aligns with fact table design (order is the grain); reduces shuffling during joins.

### Full Table Scans

- **`stg_raw_orders` WHERE clause:** Filters out ~2-5% of rows (pending/fraud). Likely uses index on `order_status` if available; otherwise full scan.
- **`int_order_items` GROUP BY:** Requires full scan to aggregate; unavoidable.
- **`int_customer_sessions` with timestamp range:** 24-hour filter reduces scan scope; should use index on `session_start`.

---

## Dependencies

### Upstream (Must Run Before This Component)

| Component | Type | Purpose | Frequency |
|---|---|---|---|
| **staging.stg_raw_orders** | Staging table | Raw order header data from source system (e.g., ERP, order management system). | Daily or real-time CDC. |
| **staging.stg_raw_customers** | Staging table | Raw customer master data from source system. | Daily or weekly snapshot. |
| **transforms.int_order_items** | Intermediate table | Pre-aggregated line-item metrics per order. Must be built before `fct_orders`. | Daily; depends on raw line items. |
| **transforms.int_customer_sessions** | Intermediate table | Session-level data with attribution and engagement metrics. Must be built before `fct_orders`. | Daily; depends on raw event logs. |

### Downstream (Components That Depend on This Output)

| Component | Type | Purpose |
|---|---|---|
| **BI Dashboards (Tableau, Looker, Power BI)** | BI tools | Primary data source for order analytics, revenue reporting, customer segmentation dashboards. |
| **Executive KPI Reports** | Reports | Revenue, AOV, conversion rate, customer lifetime value calculations. |
| **Customer Segmentation Models** | Analytics | Cohort analysis, RFM segmentation, churn prediction. |
| **Data Warehouse Cubes** | OLAP cubes | Pre-aggregated metrics for fast BI queries. |
| **Marketing Attribution Models** | Analytics | Channel performance, campaign ROI analysis. |
| **Finance/Revenue Recognition** | Finance systems | Reconciliation, revenue accrual, audit trails. |

### External Dependencies

| Dependency | Type | Purpose | Risk |
|---|---|---|---|
| **Redshift cluster availability** | Infrastructure | Table creation, query execution. | If cluster down, table cannot be refreshed. |
| **IAM roles: `analytics_readers`, `bi_team`** | Access control | GRANT statements require these roles to exist. | If roles deleted, GRANT fails; table still created but access revoked. |
| **Source system data quality** | Data | Upstream staging tables depend on clean source data. | Garbage in → garbage out; data quality issues propagate. |

---

## Additional Notes

### Maintenance & Monitoring

- **ANALYZE statement:** `ANALYZE marts.fct_orders;` updates table statistics for query optimizer. Should run after each refresh.
- **DROP TABLE IF EXISTS:** Recreates table from scratch each run (full refresh). Consider incremental updates if table grows very large (>1B rows).
- **GRANT statements:** Ensures BI team and analytics readers have SELECT access; required for downstream tools.

### Known Limitations

1. **Last-click attribution only:** Does not capture multi-touch attribution or first-click models. Consider adding additional attribution columns if needed.
2. **24-hour session lookback:** May miss sessions from previous day if order placed early morning. Adjust window if needed.
3. **No order-level discounts:** `header_discount` captured but not used in margin calculations; line-item discounts are included in `int_order_items`.
4. **Pending/fraud orders excluded:** Revenue metrics do not include these; may understate true order volume. Consider separate table for investigation.

### Future Enhancements

- Add `first_touch_channel` (from customer's first session) for multi-touch attribution.
- Add `repeat_customer_flag` and `repeat_order_count` for repeat purchase analysis.
- Add `predicted_churn_risk` score from ML model for proactive retention.
- Partition by `order_date` for faster incremental refreshes.