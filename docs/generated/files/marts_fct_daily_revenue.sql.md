# marts/fct_daily_revenue.sql

## Component Overview
- **Layer:** Marts
- **Type:** Fact table (denormalized aggregate)
- **Schedule:** Daily (inferred from naming and use case)
- **Owner:** Finance & Analytics teams (inferred from access grants)

---

## Purpose

This component creates a daily revenue summary table that aggregates order and order-item data across multiple business dimensions (product category, sales channel, geography, payment method). It serves as the single source of truth for executive dashboards and financial reporting, enabling stakeholders to quickly analyze revenue trends, margins, and performance by product, channel, and country without querying raw transactional data.

---

## Inputs

| Source | Purpose | Why Needed |
|--------|---------|-----------|
| **staging.stg_raw_orders** | Order-level metadata (date, channel, country, payment method, customer ID, order status) | Provides temporal context, channel attribution, and customer deduplication; used to filter out invalid orders (pending, fraud, cancelled) |
| **transforms.int_order_items** | Line-item details (quantity, revenue, COGS, margin, discount flags, product hierarchy) | Provides granular financial metrics and product dimensions; enables revenue and margin calculations at the item level before aggregation |

---

## Outputs

| Target | Contents | Downstream Consumers |
|--------|----------|---------------------|
| **marts.fct_daily_revenue** | Daily aggregated revenue, margin, volume, and discount metrics rolled up by date, product category/subcategory/brand, sales channel, country, and payment method | Executive dashboard, finance team reporting, BI analysts, ad-hoc revenue analysis; typically queried by date range and filtered by channel/category |

---

## Key Business Logic

### 1. **Order Status Filtering**
```
WHERE o.order_status NOT IN ('pending_payment', 'fraud_review', 'cancelled')
```
- **Why:** Only recognizes completed, shipped, or delivered orders as "revenue." Excludes orders still awaiting payment, under fraud investigation, or cancelled to prevent overstating recognized revenue.
- **Business Rule:** Aligns with revenue recognition policy (likely accrual-based at order completion, not payment).

### 2. **Revenue Metrics Hierarchy**
- **Gross Revenue** (`SUM(oi.gross_revenue)`): Total pre-discount, pre-COGS revenue; used for top-line reporting.
- **Net Revenue** (`SUM(oi.net_revenue)`): Post-discount revenue; reflects actual cash/accrual impact.
- **COGS & Gross Margin** (`SUM(oi.cogs)`, `SUM(oi.gross_margin)`): Cost of goods sold and contribution margin; used for profitability analysis.
- **Margin %** (`SUM(gross_margin) / SUM(gross_revenue) * 100`): Normalized profitability metric; enables cross-category and cross-channel comparison.

### 3. **Volume Deduplication**
- **Order Count** (`COUNT(DISTINCT o.order_id)`): Unique orders per day/dimension; prevents double-counting if an order spans multiple items.
- **Customer Count** (`COUNT(DISTINCT o.customer_id)`): Unique customers; used for cohort and retention analysis.
- **Unique Products Sold** (`COUNT(DISTINCT oi.product_id)`): Product variety metric; indicates assortment breadth.

### 4. **Discount Attribution**
```
SUM(CASE WHEN oi.is_discounted THEN oi.gross_revenue ELSE 0 END) AS discounted_revenue
ROUND(.../ NULLIF(SUM(oi.gross_revenue), 0) * 100, 2) AS discount_revenue_pct
```
- **Why:** Isolates revenue from discounted items to track promotional impact and discount elasticity.
- **Business Rule:** Assumes `is_discounted` flag is set at the item level in upstream transforms; aggregates to daily level for trend analysis.

### 5. **Average Metrics (AOV, AUP)**
```
SUM(oi.gross_revenue) / NULLIF(COUNT(DISTINCT o.order_id), 0) AS avg_order_value
SUM(oi.gross_revenue) / NULLIF(SUM(oi.quantity), 0) AS avg_unit_price
```
- **Why:** Enables pricing and basket-size analysis; used to detect shifts in customer purchasing behavior.
- **Null Handling:** `NULLIF(..., 0)` prevents division-by-zero errors; returns NULL if no orders/units exist (safer than defaulting to 0).

### 6. **Day-over-Day & Week-over-Week Comparisons**
```
LAG(SUM(oi.gross_revenue), 1) OVER (PARTITION BY oi.category, o.order_channel ORDER BY o.order_date)
LAG(SUM(oi.gross_revenue), 7) OVER (PARTITION BY oi.category, o.order_channel ORDER BY o.order_date)
```
- **Why:** Pre-calculates trend deltas to reduce BI tool query complexity; enables fast anomaly detection.
- **Partitioning Logic:** Compares same category + channel across days to isolate true growth from mix shifts.
- **Assumption:** Data is complete for all dates; missing dates will show NULL deltas (not zero).

### 7. **Granularity & Aggregation**
```
GROUP BY o.order_date, oi.category, oi.subcategory, oi.brand, o.order_channel, o.billing_country, o.payment_method
```
- **Why:** Provides flexibility for drill-down analysis (date → category → subcategory → brand) and cross-dimensional filtering (channel, country, payment method).
- **Assumption:** All GROUP BY dimensions are required; no optional hierarchies. If a dimension is NULL upstream, it will appear as a separate row.

---

## Column Descriptions

| Column | Type | Description | Example Values |
|--------|------|-------------|-----------------|
| **revenue_date** | DATE | Order date; the temporal grain of aggregation | 2024-01-15 |
| **category** | VARCHAR | Top-level product category | 'Electronics', 'Apparel', 'Home & Garden' |
| **subcategory** | VARCHAR | Secondary product classification | 'Smartphones', 'Laptops', 'Tablets' |
| **brand** | VARCHAR | Product brand | 'Apple', 'Samsung', 'Sony' |
| **order_channel** | VARCHAR | Sales channel attribution | 'Web', 'Mobile App', 'Retail Store', 'Marketplace' |
| **billing_country** | VARCHAR | Customer billing country; proxy for geography | 'US', 'CA', 'GB', 'DE' |
| **payment_method** | VARCHAR | Payment instrument used | 'Credit Card', 'PayPal', 'Apple Pay', 'Bank Transfer' |
| **order_count** | INTEGER | Distinct orders placed on this date in this dimension | 1,250 |
| **customer_count** | INTEGER | Distinct customers who placed orders | 890 |
| **units_sold** | INTEGER | Total quantity of items sold | 3,500 |
| **gross_revenue** | DECIMAL(18,2) | Total pre-discount revenue | 125,000.00 |
| **net_revenue** | DECIMAL(18,2) | Revenue after discounts applied | 118,500.00 |
| **gross_margin** | DECIMAL(18,2) | Contribution margin (revenue - COGS) | 45,000.00 |
| **margin_pct** | DECIMAL(5,2) | Gross margin as % of gross revenue | 36.00 |
| **avg_order_value** | DECIMAL(10,2) | Mean revenue per order | 100.00 |
| **avg_unit_price** | DECIMAL(10,2) | Mean revenue per unit sold | 35.71 |
| **discounted_revenue** | DECIMAL(18,2) | Revenue from items marked as discounted | 12,000.00 |
| **discount_revenue_pct** | DECIMAL(5,2) | % of total revenue from discounted items | 9.60 |
| **revenue_vs_prev_day** | DECIMAL(18,2) | Change in gross revenue vs. same category/channel yesterday | 5,000.00 |
| **revenue_vs_prev_week** | DECIMAL(18,2) | Change in gross revenue vs. same category/channel 7 days ago | 15,000.00 |
| **_loaded_at** | TIMESTAMP | ETL load timestamp; used for freshness monitoring | 2024-01-16 08:30:45 |

---

## Data Quality & Edge Cases

### Null Handling
- **Division by Zero:** `NULLIF(denominator, 0)` prevents errors in `avg_order_value`, `avg_unit_price`, and `discount_revenue_pct`. If no orders exist for a dimension, these metrics return NULL (not 0), which is semantically correct.
- **Missing Dimensions:** If `category`, `subcategory`, `brand`, `order_channel`, `billing_country`, or `payment_method` are NULL upstream, they will appear as separate rows in the output. This may inflate row count and should be monitored.
- **LAG Window Functions:** If a date is missing (no orders), the LAG will skip to the previous available date. For example, if 2024-01-15 has no orders, `revenue_vs_prev_day` on 2024-01-16 will compare to 2024-01-14, not 2024-01-15. This can mask single-day anomalies.

### Deduplication Strategy
- **Order-Level Deduplication:** `COUNT(DISTINCT o.order_id)` ensures each order is counted once, even if it contains multiple items.
- **Customer-Level Deduplication:** `COUNT(DISTINCT o.customer_id)` counts unique customers per day; a customer placing 2 orders on the same day is counted once.
- **Product-Level Deduplication:** `COUNT(DISTINCT oi.product_id)` counts unique products sold; if the same product appears in 10 orders, it's counted once.
- **No Item-Level Deduplication:** `SUM(oi.quantity)` and revenue sums are NOT deduplicated; they reflect actual transactional volume. This is correct for financial reporting.

### Key Assumptions
1. **Order Status Completeness:** Assumes `order_status` in `stg_raw_orders` is always populated and uses the exact values ('pending_payment', 'fraud_review', 'cancelled'). If new statuses are added upstream, they will be included in revenue unless the WHERE clause is updated.
2. **Item-Order Relationship:** Assumes every row in `int_order_items` has a matching `order_id` in `stg_raw_orders`. If orphaned items exist, they will be silently dropped by the INNER JOIN.
3. **Discount Flag Accuracy:** Assumes `is_discounted` flag is correctly set in `int_order_items`. If this flag is unreliable, discount metrics will be misleading.
4. **Revenue Columns Populated:** Assumes `gross_revenue`, `net_revenue`, `cogs`, and `gross_margin` are always non-null and correctly calculated upstream. If these are NULL, sums will be NULL.
5. **Temporal Continuity:** Assumes orders are dated correctly and there are no future-dated orders. If backdated or future-dated orders exist, they will distort trend analysis.
6. **No Duplicate Orders:** Assumes `order_id` is unique in `stg_raw_orders`. If duplicates exist, the INNER JOIN will create a Cartesian product, inflating metrics.

### What Could Break
- **Upstream Schema Changes:** If `int_order_items` or `stg_raw_orders` columns are renamed or removed, the query will fail.
- **New Order Statuses:** If new statuses are added (e.g., 'refunded', 'disputed'), they will be included in revenue unless the WHERE clause is updated. This could overstate revenue.
- **Null Proliferation:** If upstream data quality degrades and more NULLs appear in dimensions, row count will increase (one row per unique NULL combination), potentially causing performance issues.
- **Discount Flag Inconsistency:** If `is_discounted` logic changes upstream (e.g., threshold for "discounted" changes), historical discount metrics will become incomparable.
- **Missing Dates:** If no orders occur on a date, that date will have no rows in this table. Downstream queries using a calendar join may show zero revenue instead of NULL, depending on join type.

---

## Performance Notes

### Join Strategy
- **INNER JOIN** between `int_order_items` and `stg_raw_orders` on `order_id`:
  - **Implication:** Only orders with items are included; orders with no items are dropped. This is correct for revenue reporting but means order_count may differ from raw order counts.
  - **Assumption:** `order_id` is indexed in both tables; join should be efficient.
  - **Risk:** If `int_order_items` contains duplicate `order_id` values (e.g., due to upstream bug), the join will create duplicate rows, inflating all metrics.

### Aggregation & Grouping
- **GROUP BY 7 Dimensions:** The query groups by `order_date`, `category`, `subcategory`, `brand`, `order_channel`, `billing_country`, and `payment_method`.
  - **Cardinality Estimate:** If there are 365 dates, 10 categories, 50 subcategories, 100 brands, 5 channels, 50 countries, and 10 payment methods, the output could have up to 365 × 10 × 50 × 100 × 5 × 50 × 10 = **9.125 billion rows** (worst case, if all combinations exist). In practice, sparsity will reduce this significantly, but the table could still be large.
  - **Aggregation Cost:** Redshift will perform a full table scan of `int_order_items` and `stg_raw_orders`, then hash-aggregate. This is expensive but necessary for a daily refresh.

### Window Functions (LAG)
```
LAG(SUM(oi.gross_revenue), 1) OVER (PARTITION BY oi.category, o.order_channel ORDER BY o.order_date)
```
- **Implication:** Window functions are applied AFTER aggregation (in the SELECT clause), so they operate on the aggregated result set, not raw rows. This is efficient.
- **Partitioning:** `PARTITION BY category, order_channel` means each category-channel combination has its own LAG window. If there are 500 unique category-channel pairs, the window function will sort and compute 500 separate sequences.
- **Risk:** If `order_date` has ties (multiple rows with the same date for a category-channel pair), LAG behavior is undefined (Redshift will pick an arbitrary order). This should not happen given the GROUP BY, but it's worth noting.

### Distribution & Sort Keys
```
DISTKEY(revenue_date)
SORTKEY(revenue_date, category)
```
- **DISTKEY(revenue_date):** Distributes rows across Redshift nodes by date. This is optimal for time-series queries (e.g., "revenue for Jan 2024") but suboptimal for queries filtering by category or channel first.
  - **Implication:** Queries like "revenue by category for all time" will require a full table scan across all nodes. Queries like "revenue for Jan 15" will scan only the node(s) holding that date.
  - **Alternative:** Could use `DISTKEY(order_channel)` or `DISTKEY(category)` if those are the primary filter dimensions, but this would hurt date-range queries.
- **SORTKEY(revenue_date, category):** Sorts rows by date first, then category within each date block. This optimizes queries filtering by date range and then category.
  - **Implication:** Zone maps will prune blocks efficiently for date-range queries. Category filtering will be less efficient (requires scanning multiple blocks).

### Full Table Scans
- **Upstream Scan:** The query performs a full scan of `int_order_items` and `stg_raw_orders` (no WHERE clause on the source tables before the join). This is necessary to ensure all valid orders are included.
- **Filtering:** The WHERE clause (`order_status NOT IN (...)`) is applied after the join, so it doesn't reduce the scan size. Consider pushing this filter to the source tables if they support it.

### Expensive Operations
- **COUNT(DISTINCT ...):** Redshift must hash and deduplicate for each DISTINCT count. With 7 GROUP BY dimensions, this could be slow. Consider pre-computing distinct counts in an intermediate table if performance becomes an issue.
- **LAG Window Functions:** Sorting by `order_date` within each partition requires a sort operation. With large partitions (many category-channel pairs), this could be expensive.

### Refresh Strategy
- **Full Refresh (DROP + CREATE):** The query uses `DROP TABLE IF EXISTS` and `CREATE TABLE AS`, meaning it rebuilds the entire table daily. This is safe (no incremental logic to break) but expensive for large tables.
  - **Alternative:** Could use `DELETE FROM` + `INSERT INTO` to preserve table structure and statistics, but this requires more careful logic to avoid duplicates.

---

## Dependencies

### Upstream
| Component | Type | Why Required | Failure Impact |
|-----------|------|--------------|-----------------|
| **staging.stg_raw_orders** | Table | Provides order metadata (date, channel, country, payment method, status, customer ID) | If this table is missing or incomplete, revenue aggregation will be incorrect or fail. If order_status values change, revenue recognition logic may break. |
| **transforms.int_order_items** | Table | Provides line-item financial data (quantity, revenue, COGS, margin, discount flags, product hierarchy) | If this table is missing or has NULL revenue columns, revenue metrics will be NULL. If product hierarchy is incomplete, drill-down analysis will be limited. |
| **Redshift Cluster** | Infrastructure | Execution environment | Query will fail if cluster is down or unavailable. |

### Downstream
| Component | Type | How It Uses This Table | Dependency Type |
|-----------|------|------------------------|-----------------|
| **Executive Dashboard** | BI Tool (Tableau/Looker/etc.) | Queries `fct_daily_revenue` to display revenue trends, margin analysis, and channel performance | Hard dependency; dashboard will show stale data if this table is not refreshed daily. |
| **Finance Team Reports** | Manual/Automated Reports | Uses this table for daily revenue reconciliation, P&L reporting, and variance analysis | Hard dependency; finance team relies on this for accurate revenue recognition. |
| **Ad-Hoc BI Analysis** | Analyst Queries | Analysts query this table to investigate revenue trends, segment performance, and anomalies | Soft dependency; analysts could query raw tables, but this table is optimized for their use case. |
| **Revenue Forecasting Models** | Data Science | May use historical revenue data from this table as input features | Soft dependency; models could use raw data, but this table provides cleaner aggregates. |

### External
- **None detected.** This component does not reference external APIs, configuration files, or third-party systems.

---

## Maintenance & Monitoring

### Recommended Alerts
1. **Freshness:** Alert if `_loaded_at` is older than 24 hours (indicates failed refresh).
2. **Row Count:** Alert if row count drops by >10% or increases by >50% (indicates upstream data quality issue).
3. **NULL Metrics:** Alert if `gross_revenue` or `net_revenue` contains unexpected NULLs (indicates upstream data issue).
4. **Duplicate Orders:** Periodically check if `order_count` matches expected order volume (indicates duplicate order_id issue).

### Refresh Schedule
- **Frequency:** Daily (inferred from naming and use case).
- **Timing:** Should run after `stg_raw_orders` and `int_order_items` are refreshed (likely early morning to provide fresh data for business day).
- **SLA:** Should complete within 1-2 hours to support morning reporting.

### Access Control
- **SELECT:** Granted to `analytics_readers`, `bi_team`, `finance_team` groups.
- **No INSERT/UPDATE/DELETE:** This is a read-only mart; modifications should only occur via the daily refresh script.