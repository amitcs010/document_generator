# marts/fct_orders.sql

## Component Overview
- **Layer:** Marts
- **Type:** Fact table (denormalized, aggregated)
- **Schedule:** Not specified in code; infer from dbt/orchestration config
- **Owner:** Not specified in code; likely BI/Analytics team lead

---

## Purpose

`fct_orders` is the primary order-level fact table consumed by BI tools and analysts. It combines order header data, line-item metrics, customer attributes, and session attribution into a single denormalized table optimized for reporting and dashboard queries. This table serves as the single source of truth for order analytics, enabling business stakeholders to analyze order value, customer behavior, channel attribution, and profitability without requiring complex joins.

---

## Inputs

| Source | Purpose | Criticality |
|--------|---------|-------------|
| **staging.stg_raw_orders** | Order header data: order ID, customer ID, order date/timestamp, status, channel, payment/shipping methods, amounts (shipping, tax, discount, total). This is the core order record. | CRITICAL |
| **staging.stg_raw_customers** | Customer attributes at time of order: loyalty tier, country, registration date. Used to enrich orders with customer lifecycle context. | HIGH |
| **transforms.int_order_items** | Line-item detail: product ID, category, quantity, revenue (gross/net), COGS, margin calculations, discount flags. Aggregated to order level for metrics. | CRITICAL |
| **transforms.int_customer_sessions** | Session-level data: session ID, referrer/channel, device type, session duration, pages viewed, purchase indicator. Used for last-click attribution within 24 hours of order. | MEDIUM |

---

## Outputs

| Target | Contents | Downstream Consumers |
|--------|----------|---------------------|
| **marts.fct_orders** | Denormalized order fact table with 40+ columns spanning order header, customer, line-item metrics, attribution, and time dimensions. One row per order. | BI tools (Tableau, Looker, Power BI), SQL analysts, revenue reporting dashboards, customer analytics, channel attribution analysis |

---

## Key Business Logic

### 1. **Order Metrics Aggregation** (CTE: `order_metrics`)
Aggregates line-item data from `int_order_items` to the order level:
- **Item count & product diversity:** `COUNT(*)`, `COUNT(DISTINCT product_id)`, `COUNT(DISTINCT category)` — enables analysis of order complexity and cross-category purchasing.
- **Revenue & margin calculations:** `SUM(gross_revenue)`, `SUM(net_revenue)`, `SUM(total_cogs)`, `SUM(total_margin)` — provides profitability metrics; net revenue accounts for item-level discounts, while header-level discounts are captured separately.
- **Average margin %:** `ROUND(AVG(margin_pct), 2)` — rounded to 2 decimals for reporting consistency.
- **Discount tracking:** `SUM(CASE WHEN is_discounted THEN 1 ELSE 0 END)` — counts items with line-level discounts; combined with header-level discount flag for complete discount picture.
- **Category list:** `LISTAGG(DISTINCT category, ', ')` — human-readable list of all categories in order; enables filtering/segmentation by product mix.

**Why:** Denormalizing these metrics avoids expensive aggregations in downstream queries and ensures consistent metric definitions across all reports.

---

### 2. **Session Attribution** (CTE: `order_attribution`)
Identifies the converting session (last session before order within 24-hour lookback):
- **Join logic:** `LEFT JOIN` on `customer_id = user_id`, `session_start <= order_timestamp`, `session_start >= DATEADD(hour, -24, order_timestamp)`, and `purchase_count > 0`.
  - The 24-hour window captures the immediate pre-purchase session without attributing orders to sessions days/weeks prior.
  - `purchase_count > 0` filter ensures only sessions with purchase intent are considered (assumes this flag exists in `int_customer_sessions`).
- **Last-touch attribution:** `ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY session_start DESC)` — selects the most recent qualifying session; later filtered to `_rn = 1` in final SELECT.
- **Captured attributes:** `first_touch_referrer` (channel), `device_type`, `session_duration_sec`, `pages_viewed` — enables analysis of conversion by channel, device, and engagement level.

**Why:** Last-click attribution is a common business requirement; the 24-hour window balances attribution accuracy with practical session lifecycle. Storing session details avoids re-joining to `int_customer_sessions` in downstream queries.

**Assumption:** `int_customer_sessions.purchase_count > 0` is a reliable indicator of purchase intent. If this flag is unreliable or missing, attribution may be inaccurate.

---

### 3. **Customer Lifecycle Segmentation**
Calculates `customer_tenure_days` and `customer_lifecycle_stage` based on days since registration:
```
New (0-30d) → Growing (31-90d) → Established (91-365d) → Loyal (365d+)
```
**Why:** Enables cohort analysis and customer value segmentation without requiring a separate customer dimension table. These thresholds are business-defined; adjust if retention/LTV patterns differ.

---

### 4. **Order Flags**
Boolean columns for common filtering/segmentation:
- `used_coupon`: `coupon_code != 'NONE'` — identifies promotional orders.
- `has_discounted_items`: `discounted_items > 0` — indicates line-level discounts (independent of coupon).
- `is_refunded`: `order_status = 'refunded'` — flags refunded orders for exclusion from revenue metrics.
- `is_international`: `shipping_country != billing_country` — identifies cross-border orders.

**Why:** Pre-computed flags avoid repeated CASE statements in downstream queries and ensure consistent business logic.

---

### 5. **Time Dimensions**
Extracts temporal attributes for time-series analysis:
- `day_of_week`, `hour_of_day`, `order_month`, `week_of_year` — enables analysis by time granularity without requiring date dimension table joins.

**Why:** Denormalizing time dimensions improves query performance and simplifies BI tool configurations.

---

### 6. **Filtering Logic**
```sql
WHERE o.order_status NOT IN ('pending_payment', 'fraud_review')
```
Excludes incomplete/suspicious orders from the fact table.

**Why:** These orders lack finalized data (payment status unknown, fraud determination pending) and would skew revenue/customer metrics. They should be tracked separately if needed.

---

## Column Descriptions

| Column | Type | Description | Example |
|--------|------|-------------|---------|
| **order_id** | VARCHAR | Unique order identifier; primary key. | `ORD-2024-001234` |
| **customer_id** | VARCHAR | Foreign key to customer; enables customer-level aggregation. | `CUST-5678` |
| **order_date** | DATE | Order date (date component only); used for time-series analysis and joins to date dimensions. | `2024-01-15` |
| **order_timestamp** | TIMESTAMP | Full order timestamp; used for precise session attribution and hour-of-day analysis. | `2024-01-15 14:32:45` |
| **order_status** | VARCHAR | Order fulfillment status; filtered to exclude pending/fraud. | `completed`, `shipped`, `refunded` |
| **order_channel** | VARCHAR | Sales channel; enables channel attribution and performance analysis. | `web`, `mobile_app`, `marketplace` |
| **gross_revenue** | DECIMAL(18,2) | Sum of line-item gross revenue (before item-level discounts). | `1250.00` |
| **net_revenue** | DECIMAL(18,2) | Sum of line-item net revenue (after item-level discounts); primary revenue metric. | `1100.00` |
| **total_cogs** | DECIMAL(18,2) | Sum of line-item cost of goods sold; used for margin calculations. | `550.00` |
| **total_margin** | DECIMAL(18,2) | Sum of line-item gross margin (net_revenue - cogs); primary profitability metric. | `550.00` |
| **avg_margin_pct** | DECIMAL(5,2) | Average margin % across line items; rounded to 2 decimals. | `45.50` |
| **item_count** | INT | Number of line items in order; indicates order complexity. | `3` |
| **unique_products** | INT | Count of distinct products; indicates product diversity. | `2` |
| **total_units** | INT | Sum of quantities across all line items. | `5` |
| **categories_purchased** | VARCHAR | Comma-separated list of distinct categories; enables product mix analysis. | `Electronics, Accessories` |
| **customer_lifecycle_stage** | VARCHAR | Derived customer tenure segment; enables cohort analysis. | `New (0-30d)`, `Loyal (365d+)` |
| **attribution_channel** | VARCHAR | First-touch referrer from converting session; defaults to `unknown` if no session found. | `organic_search`, `paid_social`, `direct` |
| **conversion_device** | VARCHAR | Device type of converting session; defaults to `unknown`. | `desktop`, `mobile`, `tablet` |
| **used_coupon** | BOOLEAN | Flag indicating coupon code applied at order level. | `true`, `false` |
| **is_refunded** | BOOLEAN | Flag indicating order was refunded; use to exclude from revenue metrics. | `true`, `false` |
| **_loaded_at** | TIMESTAMP | Load timestamp; tracks when row was inserted; useful for incremental refresh logic. | `2024-01-16 02:15:30` |

---

## Data Quality & Edge Cases

### Null Handling

| Column | Null Scenario | Handling | Impact |
|--------|---------------|----------|--------|
| **attribution_channel, conversion_device** | No qualifying session found within 24-hour window or customer has no sessions. | `NVL()` defaults to `'unknown'`. | Orders without attribution are grouped as `unknown`; may inflate "unknown" channel if session data is incomplete. |
| **converting_session_id, conversion_session_duration, pre_purchase_pages** | No qualifying session. | Remain NULL; not wrapped in NVL. | Downstream queries must handle NULLs; consider adding NVL in BI layer if needed. |
| **loyalty_tier, customer_country, customer_since** | Customer record missing or deleted. | Remain NULL due to LEFT JOIN. | New/unregistered customers will have NULL customer attributes; ensure BI tools handle gracefully. |
| **coupon_code** | No coupon applied. | Assumed to be `'NONE'` (not NULL); flag logic depends on this. | If NULL values exist instead of `'NONE'`, `used_coupon` flag will be incorrect. |

### Deduplication Strategy

- **Order level:** One row per `order_id` (enforced by INNER JOIN to `order_metrics` which groups by `order_id`).
- **Session attribution:** `ROW_NUMBER()` with `_rn = 1` filter ensures only the most recent session is selected; prevents duplicate rows if multiple qualifying sessions exist.
- **Line-item aggregation:** Aggregated in `order_metrics` CTE; no duplicates in final output.

**Risk:** If `int_order_items` contains duplicate line items (e.g., due to upstream ETL bug), metrics will be inflated. Validate upstream data quality.

---

### Key Assumptions

1. **`int_order_items.is_discounted` flag is accurate** — used to count discounted items; if unreliable, discount metrics will be wrong.
2. **`int_customer_sessions.purchase_count > 0` indicates purchase intent** — if this flag is missing or always 0, no sessions will be attributed.
3. **`stg_raw_orders.coupon_code = 'NONE'` when no coupon applied** — if NULL is used instead, `used_coupon` flag will be incorrect.
4. **`order_status` values are consistent** — filtering on `NOT IN ('pending_payment', 'fraud_review')` assumes these exact status values; if statuses change, filter must be updated.
5. **Customer registration dates are accurate** — `customer_lifecycle_stage` depends on `registration_date` accuracy; if dates are backfilled or incorrect, segmentation will be wrong.
6. **Session timestamps are in same timezone as order timestamps** — 24-hour lookback window assumes consistent timezone; if not, attribution may be off by hours.

---

### What Could Break

| Scenario | Impact | Mitigation |
|----------|--------|-----------|
| **`int_order_items` contains duplicate line items** | Metrics (revenue, margin, item count) will be inflated. | Add data quality check upstream; validate `SUM(quantity)` against order header. |
| **`int_customer_sessions` is missing recent sessions** | Attribution will show `unknown` for orders that should be attributed; channel performance metrics will be skewed. | Monitor session table freshness; ensure sessions are loaded before orders. |
| **`stg_raw_customers` is stale or missing records** | Customer attributes (tenure, lifecycle stage) will be NULL or outdated. | Ensure customer table is updated daily; consider SCD Type 2 if historical customer attributes needed. |
| **Order status values change** | Filtered orders may be included/excluded incorrectly. | Maintain status value mapping; add data quality check for unexpected statuses. |
| **Session start time is after order timestamp** | Attribution will fail (no sessions qualify); all orders show `unknown` channel. | Validate session/order timestamp logic; check for timezone mismatches. |
| **`coupon_code` contains NULL instead of `'NONE'`** | `used_coupon` flag will be FALSE for orders with coupons; coupon analysis will be wrong. | Standardize coupon_code values upstream; add NOT NULL constraint. |

---

## Performance Notes

### Join Strategies

| Join | Type | Cardinality | Performance Implication |
|------|------|-------------|------------------------|
| **order_metrics (CTE)** | INNER | 1:1 (order_id) | Efficient; filters to orders with line items. Aggregation in CTE avoids repeated GROUP BY in final query. |
| **stg_raw_customers** | LEFT | N:1 (customer_id) | Efficient; customer table typically small. LEFT JOIN preserves orders with missing customer records. |
| **order_attribution (CTE)** | LEFT | 1:1 (order_id, _rn=1) | Potentially expensive; `int_customer_sessions` may be large. Join conditions include range filter (`session_start <= order_timestamp AND session_start >= DATEADD(hour, -24, order_timestamp)`), which may not use index efficiently. See optimization notes below. |

### Expensive Operations

1. **`order_attribution` CTE — Range Join on Timestamps**
   - Join condition: `s.session_start <= o.order_timestamp AND s.session_start >= DATEADD(hour, -24, o.order_timestamp)`
   - **Risk:** If `int_customer_sessions` is large (millions of rows) and lacks a clustered index on `(user_id, session_start)`, this becomes a full table scan per order.
   - **Mitigation:** Ensure `int_customer_sessions` is indexed on `(user_id, session_start)` or partitioned by date. Consider pre-filtering sessions to recent dates in `int_customer_sessions` transformation.

2. **`LISTAGG(DISTINCT category, ', ')` in `order_metrics`**
   - Aggregates all categories per order into a single string.
   - **Risk:** If orders have many categories (unlikely but possible), string concatenation may be slow. More importantly, the result is not easily queryable (e.g., can't filter "orders containing Electronics" without string parsing).
   - **Mitigation:** Consider storing categories as an array type (if database supports) or creating a separate `fct_order_categories` bridge table for better queryability.

3. **`DROP TABLE IF EXISTS` + Full Table Rebuild**
   - Entire table is dropped and recreated on each run.
   - **Risk:** If table is large (millions of rows), this is slower than incremental upsert. Also, no historical data is retained (no SCD tracking).
   - **Mitigation:** If incremental refresh is needed, switch to INSERT/UPDATE logic. If historical snapshots are needed, add `snapshot_date` column and use SCD Type 2.

### Partitioning & Distribution

```sql
DISTKEY(order_id)
SORTKEY(order_date)
```

- **DISTKEY(order_id):** Distributes rows across Redshift nodes by order_id. Ensures orders are co-located on same node, improving join performance when filtering by order_id. However, if most queries filter by `order_date` or `customer_id`, this may not be optimal.
- **SORTKEY(order_date):** Sorts rows by order_date within each node. Optimizes time-series queries (e.g., "orders in last 30 days") and range scans on date columns. Good choice for typical BI queries.

**Recommendation:** If queries frequently filter by `customer_id` (e.g., "all orders for customer X"), consider DISTKEY(customer_id) instead. If queries are evenly distributed across order_id, customer_id, and order_date, current choice is reasonable.

### Query Optimization Tips

- **Add index on `(customer_id, order_date)`** to speed up customer-level time-series queries.
- **Pre-filter `int_customer_sessions` to last 30 days** in upstream transformation to reduce join size for attribution CTE.
- **Consider materializing `order_metrics` as a separate table** if `int_order_items` is very large; avoids re-aggregating on each refresh.

---

## Dependencies

### Upstream (Must Run Before This Component)

| Component | Purpose | Frequency |
|-----------|---------|-----------|
| **staging.stg_raw_orders** | Raw order data from source system; must be loaded and validated. | Daily (or per SLA) |
| **staging.stg_raw_customers** | Raw customer data; must include registration_date and loyalty_tier. | Daily or weekly |
| **transforms.int_order_items** | Transformed line-item data with revenue, COGS, margin, discount flags. Must be aggregated correctly. | Daily (after stg_raw_orders) |
| **transforms.int_customer_sessions** | Transformed session data with referrer, device, purchase_count flag. Must include sessions from last 24 hours. | Daily (before fct_orders) |

**Critical Path:** `stg_raw_orders` → `int_order_items` → `fct_orders` (in parallel with `stg_raw_customers` and `int_customer_sessions`).

---

### Downstream (Components That Depend on This Output)

| Component | Usage | Frequency |
|-----------|-------|-----------|
| **BI Dashboards (Tableau, Looker, Power BI)** | Primary data source for order analytics, revenue reporting, channel attribution dashboards. | Real-time or hourly refresh |
| **Revenue Recognition Reports** | Finance team uses `net_revenue`, `total_margin`, `order_status` for GAAP compliance. | Daily |
| **Customer Analytics** | Marketing/Product uses `customer_lifecycle_stage`, `attribution_channel`, `order_channel` for cohort analysis. | Daily |
| **Channel Performance Analysis** | Marketing uses `attribution_channel`, `conversion_device`, `order_channel` to measure ROI by channel. | Daily |
| **Profitability Analysis** | Finance/Operations uses `total_margin`, `avg_margin_pct`, `total_cogs` to analyze product/channel profitability. | Weekly |
| **SQL Analysts** | Ad-hoc queries for custom reports; this is the primary self-service table. | On-demand |

---

### External Dependencies

| Dependency | Type | Purpose | Risk |
|------------|------|---------|------|
| **Redshift Cluster** | Infrastructure | Table is stored in Redshift; requires cluster availability. | If cluster is down, table is inaccessible. |
| **IAM Roles: `analytics_readers`, `bi_team`** | Access Control | GRANT statements depend on these roles existing. | If roles don't exist, GRANT will fail; table will be created but inaccessible. |
| **Source System (Orders, Customers, Sessions)** | Data Source | Upstream staging/transform tables depend on source system data. | If source system is down or delayed, this table will be stale. |

---

## Maintenance & Monitoring

### Recommended Checks

1. **Row count validation:** Compare row count to previous day; alert if change > 50% (indicates upstream issue).
2. **Null rate monitoring:** Track % of NULLs in `attribution_channel`, `customer_lifecycle_stage`; alert if > 10%.
3. **Revenue reconciliation:** Sum of `net_revenue` should match order header totals; validate daily.
4. **Attribution coverage:** % of orders with non-`unknown` attribution channel; alert if < 70%.
5. **Freshness check:** `MAX(_loaded_at)` should be within last 24 hours; alert if older.

### Refresh Strategy

- **Current:** Full table rebuild (DROP + CREATE) on each run.
- **Recommended:** Switch to incremental upsert (INSERT new orders, UPDATE existing orders) to reduce runtime and preserve historical data.
- **Alternative:** If historical snapshots needed, add `snapshot_date` and implement SCD Type 2 (track customer attributes changes over time).

---

## Related Documentation

- **Data Model:** See `transforms/int_order_items.sql` and `transforms/int_customer_sessions.sql` for upstream transformation logic.
- **Staging Layer:** See `staging/stg_raw_orders.sql` and `staging/stg_raw_customers.sql` for data validation rules.
- **BI Layer:** See BI tool documentation for dashboard definitions that consume this table.
- **Glossary:** See `docs/business_glossary.md` for definitions of `loyalty_tier`, `customer_lifecycle_stage`, `attribution_channel`.