# marts/fct_daily_revenue.sql

## Component Overview
- **Layer:** Marts (final consumption layer)
- **Type:** Fact table (denormalized aggregate)
- **Schedule:** Daily (inferred from "daily revenue rollup" and typical BI refresh cadence)
- **Owner:** Finance team / BI team (inferred from usage context)
- **Materialization:** Full table drop-and-recreate (non-incremental)

---

## Purpose

This table provides a daily revenue summary aggregated by product category, sales channel, and geography, enabling executives and finance teams to monitor business performance, track margin trends, and analyze discount impact across dimensions. It serves as the primary data source for executive dashboards and financial reporting, replacing ad-hoc queries with a pre-computed, optimized fact table.

---

## Inputs

| Source | Purpose | Criticality |
|--------|---------|-------------|
| **transforms.int_order_items** | Item-level revenue, cost, margin, and product dimension data (category, subcategory, brand, quantity, pricing). This is the core revenue fact data. | Critical |
| **staging.stg_raw_orders** | Order-level metadata including order date, channel, country, payment method, and order status. Used for filtering invalid orders and joining to item-level facts. | Critical |

---

## Outputs

| Target | Contents | Consumers |
|--------|----------|-----------|
| **marts.fct_daily_revenue** | Denormalized daily revenue fact table with 30+ metrics across volume, revenue, margin, discount, and trend dimensions. Indexed by date and category for BI query performance. | Executive dashboard, Finance team, BI analysts, ad-hoc reporting tools (Tableau, Looker, etc.) |

---

## Key Business Logic

### 1. **Order Status Filtering**
```
WHERE o.order_status NOT IN ('pending_payment', 'fraud_review', 'cancelled')
```
- **Why:** Only recognizes completed, revenue-generating orders. Excludes orders still awaiting payment, under fraud investigation, or cancelled to prevent revenue double-counting or false reporting.
- **Impact:** Reduces row count but ensures financial accuracy. Finance team relies on this for revenue recognition compliance.

### 2. **Revenue Aggregation & Margin Calculation**
```
SUM(oi.gross_revenue), SUM(oi.net_revenue), SUM(oi.cogs), SUM(oi.gross_margin)
ROUND(SUM(oi.gross_margin) / SUM(oi.gross_revenue) * 100, 2) AS margin_pct
```
- **Why:** Rolls up item-level revenue and cost data to daily summaries. Margin percentage is calculated as (gross_margin / gross_revenue) to show profitability as a percentage.
- **Business Rule:** Margin % is rounded to 2 decimals and defaults to 0 if gross_revenue is zero (avoiding division errors).
- **Impact:** Enables margin trend analysis and profitability monitoring by product and channel.

### 3. **Distinct Customer & Product Counting**
```
COUNT(DISTINCT o.customer_id) AS customer_count
COUNT(DISTINCT oi.product_id) AS unique_products_sold
```
- **Why:** Deduplicates customers and products within each day/category/channel combination. A customer may place multiple orders on the same day; a product may appear in multiple line items.
- **Impact:** Prevents inflated customer and product counts; enables customer acquisition and product mix analysis.

### 4. **Average Order Value (AOV) & Unit Price**
```
SUM(oi.gross_revenue) / NULLIF(COUNT(DISTINCT o.order_id), 0) AS avg_order_value
SUM(oi.gross_revenue) / NULLIF(SUM(oi.quantity), 0) AS avg_unit_price
```
- **Why:** Normalizes revenue by order count and unit count to show pricing trends and customer spending patterns.
- **Null Handling:** `NULLIF(..., 0)` prevents division-by-zero errors; result is NULL if denominator is zero (no orders or units).
- **Impact:** Supports pricing strategy analysis and customer value assessment.

### 5. **Discount Impact Analysis**
```
SUM(CASE WHEN oi.is_discounted THEN oi.gross_revenue ELSE 0 END) AS discounted_revenue
ROUND(.../ NULLIF(SUM(oi.gross_revenue), 0) * 100, 2) AS discount_revenue_pct
```
- **Why:** Isolates revenue from discounted items and calculates the percentage of total revenue that came from discounts.
- **Business Rule:** Assumes `oi.is_discounted` is a boolean flag set upstream; relies on accurate discount flagging in source data.
- **Impact:** Enables discount effectiveness tracking and margin impact analysis.

### 6. **Day-over-Day & Week-over-Week Trend Metrics**
```
LAG(SUM(oi.gross_revenue), 1) OVER (
    PARTITION BY oi.category, o.order_channel
    ORDER BY o.order_date
) AS revenue_vs_prev_day

LAG(SUM(oi.gross_revenue), 7) OVER (
    PARTITION BY oi.category, o.order_channel
    ORDER BY o.order_date
) AS revenue_vs_prev_week
```
- **Why:** Calculates revenue deltas to detect trends and anomalies. Partitioned by category and channel to isolate segment-level trends.
- **Assumption:** Assumes daily data is complete (no gaps). Missing dates will cause incorrect lag calculations.
- **Impact:** Enables trend visualization and anomaly detection in dashboards.

### 7. **Grouping & Dimensionality**
```
GROUP BY o.order_date, oi.category, oi.subcategory, oi.brand, 
         o.order_channel, o.billing_country, o.payment_method
```
- **Why:** Creates a fact table grain at the daily level, sliceable by product hierarchy (category → subcategory → brand), sales channel, geography, and payment method.
- **Impact:** Enables multi-dimensional analysis; each row represents a unique combination of these dimensions on a given day.

---

## Column Descriptions

| Column | Type | Description | Example |
|--------|------|-------------|---------|
| **revenue_date** | DATE | The order date; primary time dimension for the fact table. | 2024-01-15 |
| **category** | VARCHAR | Product category (top-level product hierarchy). | 'Electronics', 'Apparel' |
| **subcategory** | VARCHAR | Product subcategory (mid-level hierarchy). | 'Laptops', 'Shirts' |
| **brand** | VARCHAR | Product brand. | 'Dell', 'Nike' |
| **order_channel** | VARCHAR | Sales channel through which the order was placed. | 'Web', 'Mobile', 'Retail' |
| **billing_country** | VARCHAR | Country of the billing address (geography dimension). | 'US', 'CA', 'UK' |
| **payment_method** | VARCHAR | Payment method used. | 'Credit Card', 'PayPal', 'Bank Transfer' |
| **order_count** | INTEGER | Distinct count of orders for this dimension combination on this date. | 42 |
| **customer_count** | INTEGER | Distinct count of customers who placed orders in this segment on this date. | 38 |
| **units_sold** | INTEGER | Total quantity of units sold (sum of line-item quantities). | 150 |
| **gross_revenue** | DECIMAL(18,2) | Total revenue before deductions (list price × quantity). | 45000.00 |
| **net_revenue** | DECIMAL(18,2) | Revenue after returns, refunds, and adjustments. | 43500.00 |
| **gross_margin** | DECIMAL(18,2) | Gross profit (net_revenue - cogs). | 21750.00 |
| **margin_pct** | NUMERIC(5,2) | Gross margin as a percentage of gross revenue. | 48.33 |
| **avg_order_value** | DECIMAL(18,2) | Average revenue per order (gross_revenue / order_count). | 1071.43 |
| **discounted_revenue** | DECIMAL(18,2) | Total revenue from items marked as discounted. | 5000.00 |
| **discount_revenue_pct** | NUMERIC(5,2) | Percentage of gross revenue that came from discounted items. | 11.11 |
| **revenue_vs_prev_day** | DECIMAL(18,2) | Revenue change from the same dimension combination on the previous day. | 2500.00 |
| **revenue_vs_prev_week** | DECIMAL(18,2) | Revenue change from the same dimension combination 7 days ago. | -1000.00 |
| **_loaded_at** | TIMESTAMP | Timestamp when the row was inserted (data freshness marker). | 2024-01-16 08:30:00 |

---

## Data Quality & Edge Cases

### Null Handling
- **Division by Zero:** `NULLIF(denominator, 0)` is used in AOV, unit price, and discount percentage calculations. If no orders exist for a dimension combination, these metrics return NULL rather than erroring.
- **Margin Percentage:** Defaults to 0 if gross_revenue is zero (via `CASE WHEN`), preventing NULL values in a key metric.
- **Lag Calculations:** Returns NULL for the first occurrence of each (category, channel) partition (no previous day/week to compare).

### Deduplication Strategy
- **Customers:** `COUNT(DISTINCT o.customer_id)` ensures a customer counted only once per day/dimension, even if they placed multiple orders.
- **Products:** `COUNT(DISTINCT oi.product_id)` counts each product once per day/dimension, even if it appears in multiple line items.
- **Orders:** `COUNT(DISTINCT o.order_id)` counts each order once, even if it contains multiple items.

### Key Assumptions
1. **Complete Daily Data:** Lag calculations assume no gaps in the daily data. Missing dates will cause incorrect YoY/WoW comparisons.
2. **Accurate Discount Flagging:** `oi.is_discounted` must be reliably set upstream; no validation is performed here.
3. **Order Status Accuracy:** Assumes `o.order_status` is correctly maintained in the source system. Misclassified orders will skew revenue.
4. **No Late-Arriving Data:** The table is rebuilt daily; late-arriving corrections to previous days' orders will be overwritten on the next run.
5. **Product Hierarchy Stability:** Assumes category, subcategory, and brand do not change retroactively for historical orders.

### What Could Break
- **Upstream Schema Changes:** If `int_order_items` or `stg_raw_orders` columns are renamed or removed, the query will fail.
- **Data Type Mismatches:** If revenue columns are stored as strings instead of numerics, SUM() operations will fail.
- **Missing Dates:** If a date is missing from the source data, lag calculations will skip that date and produce incorrect deltas.
- **Null Revenue Values:** If `oi.gross_revenue` or `oi.net_revenue` contain unexpected NULLs, SUM() will silently treat them as 0, potentially underreporting revenue.
- **Discount Flag Inconsistency:** If `oi.is_discounted` is not consistently populated, discount metrics will be unreliable.

---

## Performance Notes

### Join Strategy
```
INNER JOIN staging.stg_raw_orders o ON oi.order_id = o.order_id
```
- **Type:** Inner join; only orders present in both tables are included.
- **Implication:** If an order exists in `int_order_items` but not in `stg_raw_orders`, it will be dropped. Conversely, orders without items are excluded.
- **Performance:** Assumes both tables are indexed on `order_id`. If not, this join could be a bottleneck.

### Aggregation & Window Functions
- **GROUP BY:** Aggregates 30+ million rows (typical order items) down to ~10k-50k rows (daily × dimensions). This is a significant reduction and should be fast.
- **Window Functions (LAG):** Applied *after* aggregation, so they operate on ~10k-50k rows, not millions. Minimal performance impact.
- **Partitioning:** LAG is partitioned by (category, channel), creating ~100-500 partitions. Each partition is sorted by date, enabling efficient lag lookups.

### Distribution & Sort Keys
```
DISTKEY(revenue_date)
SORTKEY(revenue_date, category)
```
- **DISTKEY:** Distributes rows across Redshift nodes by `revenue_date`. This ensures all rows for a given date are co-located, speeding up date-range queries.
- **SORTKEY:** Sorts rows by (revenue_date, category) within each node. Queries filtering by date and category will benefit from zone maps and block skipping.
- **Rationale:** Executive dashboards typically filter by date range and category; this key design optimizes those access patterns.
- **Trade-off:** Inserts/updates are slower due to sort key maintenance, but this table is rebuilt daily (not incrementally updated), so the cost is acceptable.

### Full Table Scan Considerations
- **No Indexes:** Redshift uses zone maps instead of traditional indexes. The sort key provides the primary optimization.
- **Typical Query Pattern:** `SELECT * FROM marts.fct_daily_revenue WHERE revenue_date BETWEEN '2024-01-01' AND '2024-01-31' AND category = 'Electronics'` will efficiently skip blocks outside the date/category range.
- **Worst Case:** Queries without date or category filters will scan the entire table (~50k rows, typically <1 second on modern Redshift).

### Materialization Strategy
- **Full Rebuild:** The table is dropped and recreated daily (`DROP TABLE IF EXISTS`), not incrementally updated. This ensures consistency but means the entire table is recomputed.
- **Cost:** ~5-10 seconds for a typical rebuild (depending on source data volume and cluster size).
- **Benefit:** No risk of partial updates or inconsistent state; each day's data is a clean snapshot.

### ANALYZE Statement
```
ANALYZE marts.fct_daily_revenue;
```
- **Purpose:** Updates table statistics (row count, column distributions) used by the Redshift query planner.
- **Impact:** Ensures subsequent queries use optimal execution plans.
- **Frequency:** Run after every rebuild to keep statistics current.

---

## Dependencies

### Upstream (Must Run Before This Component)
1. **staging.stg_raw_orders**
   - Loads raw order data from the source system (e.g., transactional database).
   - Must complete before this component runs; provides order metadata (date, channel, country, status).
   - Typical SLA: Completes by 6 AM UTC.

2. **transforms.int_order_items**
   - Transforms raw order items into a clean, denormalized format with revenue, cost, and margin calculations.
   - Must complete before this component; provides item-level facts and product dimensions.
   - Depends on `stg_raw_orders` itself, so has a transitive dependency.
   - Typical SLA: Completes by 6:30 AM UTC.

### Downstream (Depends on This Component's Output)
1. **Executive Dashboard (BI Tool)**
   - Queries `marts.fct_daily_revenue` to display daily revenue, margin trends, and channel performance.
   - Refreshes every 1-2 hours; expects data to be available by 7 AM UTC.

2. **Finance Reporting System**
   - Exports daily revenue and margin data for financial statements and variance analysis.
   - Runs at 8 AM UTC; requires this table to be fully populated.

3. **Anomaly Detection Pipeline**
   - Monitors `revenue_vs_prev_day` and `revenue_vs_prev_week` columns to flag unusual revenue drops.
   - Runs at 7:30 AM UTC; alerts finance team if deltas exceed thresholds.

4. **Data Warehouse Cubes / OLAP Systems**
   - May consume this table as a source for pre-aggregated cubes (e.g., Tableau extracts, Looker PDTs).
   - Depends on this table's availability and freshness.

### External Dependencies
- **Redshift Cluster:** Requires a running Redshift cluster with sufficient compute and storage.
- **IAM Permissions:** Requires `CREATE TABLE`, `DROP TABLE`, `SELECT`, and `GRANT` permissions on the `marts` schema.
- **User Groups:** Assumes the following groups exist and have been created:
  - `analytics_readers` — read-only access for analysts
  - `bi_team` — read-only access for BI tool service accounts
  - `finance_team` — read-only access for finance users
- **Orchestration Tool:** Typically scheduled via Airflow, dbt, or similar; assumes a daily trigger at 6:45 AM UTC (after upstream dependencies complete).

---

## Maintenance & Operational Notes

### Refresh Cadence
- **Frequency:** Daily, typically at 6:45 AM UTC (after upstream tables complete).
- **Duration:** ~5-10 seconds for the full rebuild.
- **Retention:** All historical data is retained; no archival or purging.

### Monitoring & Alerts
- **Row Count:** Monitor for unexpected drops (e.g., if order status filtering becomes too aggressive).
- **Null Rates:** Alert if margin_pct or avg_order_value exceed 5% nulls (indicates upstream data quality issues).
- **Lag Calculation Accuracy:** Spot-check `revenue_vs_prev_day` and `revenue_vs_prev_week` against manual calculations to ensure correctness.

### Common Troubleshooting
| Issue | Cause | Resolution |
|-------|-------|-----------|
| Query timeout | Table too large or inefficient query plan | Check sort key usage; add date filter to queries |
| Null margin_pct values | Zero gross_revenue for a dimension combination | Expected; indicates no revenue for that segment |
| Incorrect lag values | Missing dates in source data | Investigate upstream data completeness |
| Permission denied on GRANT | User lacks admin privileges | Ensure orchestration user has schema ownership |