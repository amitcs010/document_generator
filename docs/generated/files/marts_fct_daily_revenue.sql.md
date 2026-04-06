# marts/fct_daily_revenue.sql

## Component Overview
- **Layer:** Marts
- **Type:** Fact table (denormalized aggregate)
- **Schedule:** Daily (inferred from "daily revenue rollup" and typical BI refresh cadence)
- **Owner:** Finance team / BI team (inferred from usage context)

---

## Purpose

This component creates a daily revenue summary table that aggregates order and order-item data across product categories, sales channels, and geographies. It serves as the primary data source for executive dashboards and financial reporting, enabling leadership and finance teams to monitor revenue performance, margin trends, and channel effectiveness without querying raw transactional data.

---

## Inputs

| Source | Purpose | Critical Attributes |
|--------|---------|---------------------|
| **transforms.int_order_items** | Provides line-item revenue, cost, margin, and product classification data. This component needs it to calculate revenue metrics and segment by product hierarchy (category, subcategory, brand). | `order_id`, `product_id`, `category`, `subcategory`, `brand`, `quantity`, `gross_revenue`, `net_revenue`, `cogs`, `gross_margin`, `is_discounted` |
| **staging.stg_raw_orders** | Provides order-level context including date, channel, geography, payment method, and order status. This component needs it to filter valid orders and segment revenue by business dimensions. | `order_id`, `customer_id`, `order_date`, `order_status`, `order_channel`, `billing_country`, `payment_method` |

---

## Outputs

| Target | Contents | Downstream Consumers |
|--------|----------|---------------------|
| **marts.fct_daily_revenue** | Denormalized daily revenue fact table with ~25 columns spanning volume metrics (order/customer/product counts), revenue metrics (gross/net/margin), averages (AOV, unit price), discount analysis, and day-over-day/week-over-week comparisons. One row per unique combination of `(revenue_date, category, subcategory, brand, order_channel, billing_country, payment_method)`. | Executive dashboard, Finance team reporting, BI analysts, ad-hoc revenue analysis queries |

---

## Key Business Logic

### 1. **Order Status Filtering**
```
WHERE o.order_status NOT IN ('pending_payment', 'fraud_review', 'cancelled')
```
- **Why:** Only completed, legitimate orders should contribute to revenue reporting. Pending payments haven't been collected, fraud-review orders are under investigation, and cancelled orders represent no revenue.
- **Business Impact:** Ensures reported revenue reflects actual cash/recognized transactions only.

### 2. **Revenue Aggregation & Margin Calculation**
```
SUM(oi.gross_revenue) AS gross_revenue
SUM(oi.net_revenue) AS net_revenue
SUM(oi.cogs) AS cogs
SUM(oi.gross_margin) AS gross_margin
ROUND(SUM(oi.gross_margin) / SUM(oi.gross_revenue) * 100, 2) AS margin_pct
```
- **Why:** Aggregates line-item revenue and costs to the daily level. Margin percentage is calculated as a ratio to show profitability as a percentage of gross revenue.
- **Business Impact:** Enables finance to track daily profitability trends and identify high/low-margin product categories or channels.
- **Edge Case:** Division by zero is handled with `CASE WHEN SUM(oi.gross_revenue) > 0` to avoid errors on zero-revenue days.

### 3. **Customer & Product Deduplication**
```
COUNT(DISTINCT o.customer_id) AS customer_count
COUNT(DISTINCT oi.product_id) AS unique_products_sold
```
- **Why:** Uses `DISTINCT` to count unique customers and products per day, avoiding inflated counts from customers with multiple orders or products appearing in multiple line items.
- **Business Impact:** Provides accurate customer acquisition/engagement metrics and product diversity metrics.

### 4. **Average Order Value (AOV) & Unit Price**
```
ROUND(SUM(oi.gross_revenue) / NULLIF(COUNT(DISTINCT o.order_id), 0), 2) AS avg_order_value
ROUND(SUM(oi.gross_revenue) / NULLIF(SUM(oi.quantity), 0), 2) AS avg_unit_price
```
- **Why:** Calculates per-order and per-unit economics. `NULLIF` prevents division-by-zero errors.
- **Business Impact:** Tracks pricing power and order size trends; useful for identifying channel or category performance.

### 5. **Discount Analysis**
```
SUM(CASE WHEN oi.is_discounted THEN oi.gross_revenue ELSE 0 END) AS discounted_revenue
ROUND(.../ NULLIF(SUM(oi.gross_revenue), 0) * 100, 2) AS discount_revenue_pct
```
- **Why:** Isolates revenue from discounted items and calculates the percentage of total revenue that came from promotions.
- **Business Impact:** Enables finance to measure promotional effectiveness and margin impact of discounting strategies.

### 6. **Day-over-Day & Week-over-Week Comparisons**
```
SUM(oi.gross_revenue) - LAG(SUM(oi.gross_revenue), 1) OVER (
    PARTITION BY oi.category, o.order_channel
    ORDER BY o.order_date
) AS revenue_vs_prev_day

SUM(oi.gross_revenue) - LAG(SUM(oi.gross_revenue), 7) OVER (
    PARTITION BY oi.category, o.order_channel
    ORDER BY o.order_date
) AS revenue_vs_prev_week
```
- **Why:** Window functions compute revenue deltas within each category-channel combination, enabling trend analysis without requiring separate queries.
- **Business Impact:** Dashboards can display performance trends and anomalies (e.g., sudden drops) at a glance.
- **Assumption:** Data is complete for all dates; missing dates will show NULL comparisons.

### 7. **Granular Segmentation**
```
GROUP BY o.order_date, oi.category, oi.subcategory, oi.brand, 
         o.order_channel, o.billing_country, o.payment_method
```
- **Why:** Preserves multiple dimensions of analysis (product hierarchy, sales channel, geography, payment type) in a single denormalized table.
- **Business Impact:** Eliminates need for joins in downstream queries; BI tools can slice/dice across any dimension without performance penalty.

---

## Column Descriptions

| Column | Data Type | Description | Example Values |
|--------|-----------|-------------|-----------------|
| **revenue_date** | DATE | The order date; represents the day revenue was recognized. | `2024-01-15` |
| **category** | VARCHAR | Top-level product category. | `Electronics`, `Apparel`, `Home & Garden` |
| **subcategory** | VARCHAR | Secondary product classification. | `Smartphones`, `T-Shirts`, `Bedding` |
| **brand** | VARCHAR | Product brand. | `Apple`, `Nike`, `IKEA` |
| **order_channel** | VARCHAR | Sales channel through which the order was placed. | `Web`, `Mobile App`, `In-Store`, `Marketplace` |
| **billing_country** | VARCHAR | Country of the billing address. | `US`, `CA`, `GB`, `DE` |
| **payment_method** | VARCHAR | Payment instrument used. | `Credit Card`, `PayPal`, `Apple Pay`, `Bank Transfer` |
| **order_count** | INTEGER | Number of distinct orders on this date for this segment. | `1250` |
| **customer_count** | INTEGER | Number of distinct customers who placed orders on this date for this segment. | `980` |
| **units_sold** | INTEGER | Total quantity of items sold. | `3500` |
| **unique_products_sold** | INTEGER | Number of distinct product SKUs sold. | `145` |
| **gross_revenue** | DECIMAL(18,2) | Total revenue before discounts and returns. | `125000.00` |
| **net_revenue** | DECIMAL(18,2) | Revenue after discounts and returns. | `118500.00` |
| **cogs** | DECIMAL(18,2) | Cost of goods sold. | `65000.00` |
| **gross_margin** | DECIMAL(18,2) | Gross profit (gross_revenue - cogs). | `60000.00` |
| **margin_pct** | DECIMAL(5,2) | Gross margin as a percentage of gross revenue. | `48.00` |
| **avg_order_value** | DECIMAL(10,2) | Average revenue per order. | `100.00` |
| **avg_unit_price** | DECIMAL(10,2) | Average revenue per unit sold. | `35.71` |
| **discounted_revenue** | DECIMAL(18,2) | Total revenue from items marked as discounted. | `12500.00` |
| **discount_revenue_pct** | DECIMAL(5,2) | Percentage of total revenue from discounted items. | `10.00` |
| **revenue_vs_prev_day** | DECIMAL(18,2) | Change in gross revenue compared to the same segment on the previous day. | `5000.00`, `-2500.00`, `NULL` (if no prior day) |
| **revenue_vs_prev_week** | DECIMAL(18,2) | Change in gross revenue compared to the same segment 7 days prior. | `15000.00`, `-8000.00`, `NULL` (if no data 7 days ago) |
| **_loaded_at** | TIMESTAMP | Timestamp when the row was inserted/refreshed. | `2024-01-16 02:30:45` |

---

## Data Quality & Edge Cases

### Null Handling
- **`NULLIF()` in division:** Used in `avg_order_value`, `avg_unit_price`, `margin_pct`, and `discount_revenue_pct` to prevent division-by-zero errors. Results will be `NULL` if denominator is zero.
  - **Example:** If a segment has zero orders, `avg_order_value` will be `NULL` rather than an error.
- **Window function comparisons:** `revenue_vs_prev_day` and `revenue_vs_prev_week` will be `NULL` for the first occurrence of a segment or if no data exists for the comparison date.
  - **Example:** The first day of data for a new category-channel combination will have `NULL` for both comparison columns.

### Deduplication Strategy
- **Order-level metrics:** `COUNT(DISTINCT o.order_id)` ensures each order is counted once, even if it contains multiple line items.
- **Customer-level metrics:** `COUNT(DISTINCT o.customer_id)` counts each customer once per day, even if they placed multiple orders.
- **Product-level metrics:** `COUNT(DISTINCT oi.product_id)` counts each product once, even if it appears in multiple line items.
- **Assumption:** `order_id` and `customer_id` are unique identifiers with no duplicates in source tables.

### Key Assumptions About Upstream Data
1. **`stg_raw_orders.order_date` is populated and valid** for all rows; no NULL dates.
2. **`int_order_items` contains one row per order line item** with no duplicates; revenue and cost fields are pre-calculated and accurate.
3. **`is_discounted` flag is correctly set** in `int_order_items` to identify promotional items.
4. **`order_status` values are consistent** and match the hardcoded list in the WHERE clause.
5. **Foreign key relationship** (`order_id`) between `stg_raw_orders` and `int_order_items` is valid; no orphaned line items.

### What Could Break
- **Missing order dates:** If `stg_raw_orders.order_date` contains NULLs, those rows will be excluded from aggregation silently.
- **Duplicate order IDs:** If `stg_raw_orders` contains duplicate `order_id` values, `COUNT(DISTINCT o.order_id)` will undercount orders.
- **Inconsistent `order_status` values:** If new status values are introduced upstream (e.g., `refunded`, `on_hold`), they will be included in revenue unless the WHERE clause is updated.
- **Missing line items:** If an order exists in `stg_raw_orders` but has no rows in `int_order_items`, it will not appear in this table (INNER JOIN).
- **Negative revenue/cost values:** The query does not validate that revenue and cost fields are positive; negative values will aggregate normally, potentially masking data quality issues.
- **Timezone issues:** `order_date` is assumed to be in a consistent timezone; if source data mixes timezones, daily aggregations may be misaligned.

---

## Performance Notes

### Join Strategy
```
INNER JOIN staging.stg_raw_orders o ON oi.order_id = o.order_id
```
- **Type:** INNER JOIN on `order_id`.
- **Implication:** Only orders with matching line items are included. If `stg_raw_orders` is larger than `int_order_items`, this join filters the result set significantly.
- **Performance:** Assumes `order_id` is indexed in both tables; join should be efficient.

### Aggregation & Window Functions
- **GROUP BY:** Aggregates across 7 dimensions (`order_date`, `category`, `subcategory`, `brand`, `order_channel`, `billing_country`, `payment_method`). This creates a potentially large intermediate result set before window functions are applied.
- **Window Functions:** `LAG()` is applied *after* aggregation, partitioned by `category` and `order_channel`. This is efficient because the window operates on the grouped result set, not raw rows.
- **Expensive Operations:** The `DISTINCT` counts (`COUNT(DISTINCT o.customer_id)`, `COUNT(DISTINCT oi.product_id)`) require scanning all rows in each group; these are relatively expensive but necessary for accuracy.

### Distribution & Sort Keys
```
DISTKEY(revenue_date)
SORTKEY(revenue_date, category)
```
- **DISTKEY:** Data is distributed across Redshift nodes by `revenue_date`. This is appropriate for a daily table because:
  - Queries typically filter by date range (e.g., "last 30 days").
  - Distributing by date co-locates all data for a given day on the same node, reducing network traffic for date-filtered queries.
- **SORTKEY:** Rows are sorted by `revenue_date` (primary) and `category` (secondary). This enables:
  - Efficient range scans for date-based queries.
  - Efficient filtering/grouping by category after date filtering.
  - Efficient window function execution (LAG is partitioned by category).
- **Trade-off:** If queries frequently filter by `order_channel` or `billing_country` instead of date, performance may be suboptimal.

### Full Table Scans
- The `CREATE TABLE AS SELECT` statement performs a full scan of both source tables. On large datasets, this can be time-consuming.
- The `ANALYZE` command at the end updates table statistics, which is necessary for the query optimizer to make good decisions on downstream queries.

### Scalability Considerations
- **Row count:** With 7 GROUP BY dimensions, the output table can grow large. For example, if there are 100 categories, 50 subcategories, 500 brands, 5 channels, 50 countries, and 10 payment methods, the theoretical maximum is 100 × 50 × 500 × 5 × 50 × 10 = 1.25 billion rows per day. In practice, the cardinality is much lower, but this should be monitored.
- **Incremental refresh:** The current design uses `DROP TABLE IF EXISTS` and full rebuild. For large tables, consider implementing incremental inserts (e.g., only insert/update rows for the current day) to reduce load time.

---

## Dependencies

### Upstream (Must Run Before This Component)
1. **staging.stg_raw_orders**
   - Loads raw order data from source systems.
   - Must complete before this component runs.
   - If this table is missing or incomplete, this component will produce incomplete results.

2. **transforms.int_order_items**
   - Transforms raw order items, calculates revenue/margin, and adds product classifications.
   - Must complete before this component runs.
   - If this table is missing or has stale data, this component will produce stale results.

### Downstream (Depends on This Component's Output)
1. **Executive Dashboard** (BI tool, e.g., Tableau, Looker, Power BI)
   - Queries `marts.fct_daily_revenue` to display KPIs: daily revenue, margin %, AOV, channel performance.
   - Requires this table to be refreshed daily for up-to-date dashboards.

2. **Finance Team Reports**
   - Uses this table for daily revenue reconciliation, margin analysis, and channel profitability reports.
   - Depends on accurate, timely data.

3. **Ad-Hoc BI Queries**
   - Analysts query this table directly for revenue analysis, trend analysis, and anomaly detection.
   - Depends on this table being available and performant.

4. **Data Warehouse / Data Lake**
   - This table may be exported or replicated to downstream data lakes or external BI platforms.
   - Any downstream system depending on this export depends on this component.

### External Dependencies
- **Redshift Cluster:** Requires a running Redshift cluster with sufficient storage and compute capacity.
- **IAM/Permissions:** Requires `SELECT` permissions on source tables and `CREATE TABLE` permissions on the `marts` schema.
- **User Groups:** Grants are issued to `analytics_readers`, `bi_team`, and `finance_team` groups; these groups must exist in Redshift.

### Data Lineage
```
Raw Source Systems
    ↓
staging.stg_raw_orders
    ↓
transforms.int_order_items ←─┐
    ↓                         │
    └─────────────────────────┘
    ↓
marts.fct_daily_revenue
    ↓
Executive Dashboard, Finance Reports, BI Queries
```

---

## Maintenance & Monitoring

### Recommended Monitoring
- **Row count trend:** Monitor the number of rows inserted daily to detect anomalies (e.g., sudden drop in orders).
- **Null values:** Track the percentage of NULL values in `revenue_vs_prev_day` and `revenue_vs_prev_week` to detect missing historical data.
- **Margin outliers:** Alert if `margin_pct` falls below a threshold (e.g., < 20%) for any segment, indicating potential data quality or business issues.
- **Load time:** Monitor the time taken to rebuild this table; if it exceeds SLA, consider incremental refresh or partitioning strategies.

### Refresh Schedule
- **Frequency:** Daily (inferred from "daily revenue rollup").
- **Timing:** Should run after `transforms.int_order_items` and `staging.stg_raw_orders` are complete.
- **Recommended time:** Early morning (e.g., 2–3 AM) to provide fresh data for business users by start of business day.

### Known Limitations
- **Latency:** Data reflects orders as of the previous day; real-time revenue is not available.
- **Incomplete days:** If the refresh runs before all orders for the day are loaded, the current day's revenue will be understated.
- **Recalculation:** If source data is corrected retroactively, this table must be manually refreshed to reflect corrections.