# marts/fct_daily_revenue.sql

## Component Overview
- **Layer:** Marts
- **Type:** Fact table (denormalized aggregate)
- **Schedule:** Daily (inferred from naming and use case; typically runs post-ETL completion)
- **Owner:** Finance & Analytics teams (inferred from stakeholder grants)

---

## Purpose

This component aggregates order-level transactional data into daily revenue summaries, rolled up by product category, sales channel, and geography. It powers executive dashboards and financial reporting by providing pre-calculated metrics (revenue, margin, order counts, discounts) that would be expensive to compute on-demand. The table is optimized for time-series analysis and trend comparison across business dimensions.

---

## Inputs

| Source | Purpose | Critical Attributes |
|--------|---------|---------------------|
| **transforms.int_order_items** | Item-level revenue data (quantity, gross/net revenue, COGS, margin, discount flags) | `order_id`, `product_id`, `category`, `subcategory`, `brand`, `quantity`, `gross_revenue`, `net_revenue`, `cogs`, `gross_margin`, `is_discounted` |
| **staging.stg_raw_orders** | Order header data (dates, channels, customer IDs, payment methods, order status) | `order_id`, `order_date`, `customer_id`, `order_channel`, `billing_country`, `payment_method`, `order_status` |

---

## Outputs

| Target | Contents | Consumers |
|--------|----------|-----------|
| **marts.fct_daily_revenue** | Daily revenue fact table with 25+ metrics across 7 dimensions (date, category, subcategory, brand, channel, country, payment method) | Executive dashboard, Finance team (reporting/forecasting), BI analysts, CFO/controller reviews |

---

## Key Business Logic

### 1. **Order Status Filtering**
```
WHERE o.order_status NOT IN ('pending_payment', 'fraud_review', 'cancelled')
```
- **Why:** Only recognizes completed, revenue-generating orders. Excludes orders still awaiting payment, under fraud investigation, or cancelled (which have no economic impact).
- **Business rule:** Revenue is recognized only when order status indicates fulfillment/completion.

### 2. **Revenue Metrics Hierarchy**
- **Gross Revenue** (`SUM(oi.gross_revenue)`): Total invoice value before deductions; used for top-line reporting.
- **Net Revenue** (`SUM(oi.net_revenue)`): Revenue after returns/adjustments; used for actual cash impact analysis.
- **COGS** (`SUM(oi.cogs)`): Cost of goods sold; enables margin calculation.
- **Gross Margin** (`SUM(oi.gross_margin)`): Absolute margin dollars; used for profitability trending.
- **Margin %** (`SUM(gross_margin) / SUM(gross_revenue) * 100`): Normalized margin; enables cross-category/channel comparison.
  - **Edge case handling:** `CASE WHEN SUM(oi.gross_revenue) > 0` prevents division by zero on zero-revenue days.

### 3. **Volume & Engagement Metrics**
- **Order Count** (`COUNT(DISTINCT o.order_id)`): Distinct orders per day/dimension; deduplicates multi-item orders.
- **Customer Count** (`COUNT(DISTINCT o.customer_id)`): Unique customers; measures market reach.
- **Units Sold** (`SUM(oi.quantity)`): Total item quantity; used for inventory/demand analysis.
- **Unique Products Sold** (`COUNT(DISTINCT oi.product_id)`): Product variety; indicates assortment breadth.

### 4. **Average Metrics (Per-Order & Per-Unit Economics)**
- **AOV** (`SUM(gross_revenue) / COUNT(DISTINCT order_id)`): Average order value; tracks customer spend trends.
- **AUP** (`SUM(gross_revenue) / SUM(quantity)`): Average unit price; detects pricing/mix shifts.
  - **Null handling:** `NULLIF(..., 0)` prevents division by zero if no orders or units exist on a day.

### 5. **Discount Analysis**
- **Discounted Revenue** (`SUM(CASE WHEN is_discounted THEN gross_revenue ELSE 0 END)`): Total revenue from discounted items.
- **Discount Revenue %** (`discounted_revenue / SUM(gross_revenue) * 100`): Proportion of revenue from discounts; tracks promotional intensity.
  - **Assumption:** `is_discounted` flag is reliably set in `int_order_items`; if missing/null, discounted items are excluded.

### 6. **Year-over-Year & Week-over-Week Comparisons**
```sql
LAG(SUM(oi.gross_revenue), 1) OVER (
    PARTITION BY oi.category, o.order_channel
    ORDER BY o.order_date
)
```
- **revenue_vs_prev_day:** Day-over-day change in revenue within each category/channel; detects anomalies.
- **revenue_vs_prev_week:** Week-over-week change; smooths daily volatility.
  - **Window function logic:** Partitions by category + channel to isolate trends; orders by date to ensure correct lag alignment.
  - **Edge case:** First day of data for a category/channel will have NULL lag values (no prior day/week to compare).

### 7. **Aggregation Granularity**
```sql
GROUP BY o.order_date, oi.category, oi.subcategory, oi.brand, 
         o.order_channel, o.billing_country, o.payment_method
```
- **7-dimensional rollup:** Enables drill-down from daily totals → category → subcategory → brand, and cross-tabulation by channel/country/payment method.
- **Deduplication:** `COUNT(DISTINCT order_id)` and `COUNT(DISTINCT customer_id)` ensure multi-item orders are counted once per order/customer.

---

## Column Descriptions

| Column | Type | Description | Example |
|--------|------|-------------|---------|
| **revenue_date** | DATE | Order date; primary time dimension for trend analysis. | `2024-01-15` |
| **category** | VARCHAR | Product category (e.g., Electronics, Apparel). | `Electronics` |
| **subcategory** | VARCHAR | Product subcategory for detailed segmentation. | `Laptops` |
| **brand** | VARCHAR | Product brand; enables brand-level P&L. | `Dell` |
| **order_channel** | VARCHAR | Sales channel (e.g., Web, Mobile, Retail). | `Web` |
| **billing_country** | VARCHAR | Customer billing country; enables geo-revenue analysis. | `US` |
| **payment_method** | VARCHAR | Payment type (e.g., Credit Card, PayPal). | `Credit Card` |
| **order_count** | INT | Distinct orders on this date/dimension. | `1,250` |
| **customer_count** | INT | Distinct customers on this date/dimension. | `980` |
| **units_sold** | INT | Total quantity of items sold. | `3,500` |
| **gross_revenue** | DECIMAL(18,2) | Total invoice value before deductions. | `125,000.00` |
| **net_revenue** | DECIMAL(18,2) | Revenue after returns/adjustments. | `122,500.00` |
| **gross_margin** | DECIMAL(18,2) | Absolute margin dollars (revenue − COGS). | `45,000.00` |
| **margin_pct** | DECIMAL(5,2) | Margin as % of gross revenue. | `36.00` |
| **avg_order_value** | DECIMAL(10,2) | Average revenue per order. | `100.00` |
| **avg_unit_price** | DECIMAL(10,2) | Average revenue per unit sold. | `35.71` |
| **discounted_revenue** | DECIMAL(18,2) | Revenue from items with discount flag. | `15,000.00` |
| **discount_revenue_pct** | DECIMAL(5,2) | % of revenue from discounted items. | `12.00` |
| **revenue_vs_prev_day** | DECIMAL(18,2) | Day-over-day revenue change within category/channel. | `5,000.00` or `NULL` (first day) |
| **revenue_vs_prev_week** | DECIMAL(18,2) | Week-over-week revenue change within category/channel. | `−2,500.00` or `NULL` (first week) |
| **_loaded_at** | TIMESTAMP | Load timestamp; data freshness indicator. | `2024-01-16 02:30:45` |

---

## Data Quality & Edge Cases

### Null Handling
| Scenario | Handling | Impact |
|----------|----------|--------|
| Zero orders on a day | `NULLIF(COUNT(DISTINCT order_id), 0)` in denominator → `avg_order_value` = NULL | Prevents misleading $0 AOV; analysts must filter out NULL AOV rows. |
| Zero units sold | `NULLIF(SUM(quantity), 0)` in denominator → `avg_unit_price` = NULL | Prevents division by zero; rare but possible if all items are returns. |
| Zero gross revenue | `CASE WHEN SUM(gross_revenue) > 0` → `margin_pct` = 0 | Conservative: treats zero-revenue days as 0% margin (not NULL). |
| Missing `is_discounted` flag | Treated as FALSE; item excluded from `discounted_revenue` | **Risk:** If upstream `int_order_items` has NULL `is_discounted`, discounts are undercounted. |
| First day/week for category/channel | `LAG()` returns NULL for `revenue_vs_prev_day` / `revenue_vs_prev_week` | Expected; BI tools must handle NULL comparisons. |

### Deduplication Strategy
- **Order-level deduplication:** `COUNT(DISTINCT o.order_id)` ensures multi-item orders counted once.
- **Customer-level deduplication:** `COUNT(DISTINCT o.customer_id)` ensures repeat customers counted once per day.
- **Product-level deduplication:** `COUNT(DISTINCT oi.product_id)` counts unique SKUs sold (not quantity).
- **Assumption:** `order_id` and `customer_id` are unique identifiers with no duplicates in source tables.

### Business Rule Assumptions
1. **Order Status Logic:** `order_status` values are standardized (e.g., 'pending_payment', 'fraud_review', 'cancelled', 'completed', 'shipped'). If new statuses are added upstream, filtering logic may need revision.
2. **Revenue Recognition:** Revenue is recognized on `order_date` (not shipment/payment date). If business rules change to recognize on payment date, this table must be rebuilt.
3. **Discount Flag Reliability:** `is_discounted` is accurately set in `int_order_items`. If this flag is missing or incorrectly populated, discount metrics are unreliable.
4. **COGS Accuracy:** `cogs` values are populated and accurate. Missing COGS → incorrect margin calculations.
5. **No Order Splits:** Assumes each `order_id` belongs to exactly one `order_date` and `customer_id`. If orders can span multiple dates, grouping logic breaks.

### What Could Break
| Change | Impact | Mitigation |
|--------|--------|-----------|
| New order status added (e.g., 'on_hold') | Status not filtered; revenue may be double-counted if status is later changed to 'completed'. | Update WHERE clause; coordinate with source system owner. |
| `is_discounted` flag removed from `int_order_items` | Discount metrics become NULL/0; BI dashboards show no discounts. | Add discount detection logic (e.g., `WHERE list_price > actual_price`). |
| `order_date` changes to `payment_date` in `stg_raw_orders` | Revenue attributed to wrong date; trend analysis breaks. | Validate upstream schema changes before rebuild. |
| Duplicate `order_id` values in `stg_raw_orders` | `COUNT(DISTINCT order_id)` still works, but join may produce duplicate rows if not caught. | Add data quality check: `SELECT order_id, COUNT(*) FROM stg_raw_orders GROUP BY order_id HAVING COUNT(*) > 1`. |
| NULL values in `category`, `channel`, or `country` | Rows grouped under NULL dimension; hard to debug. | Add NOT NULL checks in upstream `int_order_items` and `stg_raw_orders`. |

---

## Performance Notes

### Join Strategy
```sql
INNER JOIN staging.stg_raw_orders o ON oi.order_id = o.order_id
```
- **Type:** INNER JOIN (only matched orders included).
- **Key:** `order_id` (assumed unique in both tables).
- **Implication:** If `int_order_items` has orphaned `order_id` values (no match in `stg_raw_orders`), those items are silently dropped. **Risk:** Data loss if upstream ETL fails.
- **Mitigation:** Add pre-join validation: `SELECT COUNT(*) FROM int_order_items WHERE order_id NOT IN (SELECT order_id FROM stg_raw_orders)`.

### Aggregation & Window Functions
- **GROUP BY:** 7 dimensions (date, category, subcategory, brand, channel, country, payment method) → potentially millions of rows if data is granular.
- **Window Functions:** `LAG()` partitioned by category + channel; requires sorting by date. **Cost:** O(n log n) sort per partition; acceptable for daily refresh but expensive if run hourly.
- **Full Table Scan:** No WHERE clause on `int_order_items` (only on `stg_raw_orders`); entire order items table is scanned. **Implication:** Performance scales with order item volume.

### Partitioning & Distribution Keys
```sql
DISTKEY(revenue_date)
SORTKEY(revenue_date, category)
```
- **DISTKEY(revenue_date):** Distributes rows across Redshift nodes by date. **Rationale:** Most queries filter by date range; co-locates related rows on same node, reducing network traffic.
- **SORTKEY(revenue_date, category):** Sorts within each node by date, then category. **Rationale:** Enables efficient range scans on date (e.g., "last 30 days") and category filtering.
- **Trade-off:** Optimizes for time-series queries (common in BI) but may slow down queries filtering primarily by channel or country (secondary sort key).

### Expensive Operations
| Operation | Cost | Mitigation |
|-----------|------|-----------|
| `COUNT(DISTINCT order_id)` | O(n) scan + dedup; expensive if millions of orders. | Redshift optimizes DISTINCT; acceptable for daily aggregation. |
| `LAG()` window function | Requires full sort by date per partition; O(n log n). | Partition by category + channel to reduce sort scope; acceptable for daily refresh. |
| `SUM(CASE WHEN is_discounted...)` | Conditional aggregation; O(n) scan. | Acceptable; no index available on boolean flag. |

### Materialization Strategy
- **DROP TABLE IF EXISTS + CREATE AS:** Full table rebuild on each run (no incremental updates).
- **Implication:** Entire table is recomputed daily; no delta logic.
- **Rationale:** Ensures data consistency and simplifies logic (no need to track which dates changed upstream).
- **Cost:** Acceptable for daily schedule; would be prohibitive for hourly refreshes.

---

## Dependencies

### Upstream (Must Run Before This Component)
1. **staging.stg_raw_orders**
   - Loads raw order data from source system.
   - Must complete before this component runs.
   - **Critical columns:** `order_id`, `order_date`, `customer_id`, `order_channel`, `billing_country`, `payment_method`, `order_status`.

2. **transforms.int_order_items**
   - Transforms raw order items; calculates revenue, COGS, margin, discount flags.
   - Must complete before this component runs.
   - **Critical columns:** `order_id`, `product_id`, `category`, `subcategory`, `brand`, `quantity`, `gross_revenue`, `net_revenue`, `cogs`, `gross_margin`, `is_discounted`.

### Downstream (Depends on This Component's Output)
1. **Executive Dashboard** (BI tool, e.g., Tableau/Looker)
   - Consumes `fct_daily_revenue` for KPI cards, trend charts, and drill-down reports.
   - Filters by date range, category, channel, country.

2. **Finance Reporting** (e.g., monthly P&L, revenue forecasting)
   - Aggregates `fct_daily_revenue` to monthly/quarterly totals.
   - Validates against GL (general ledger) for reconciliation.

3. **BI Analyst Queries** (ad-hoc analysis)
   - Joins with dimension tables (e.g., `dim_product`, `dim_customer`) for deeper insights.
   - Filters by specific dimensions (e.g., "Electronics revenue by country").

4. **Downstream Marts** (if any)
   - E.g., `marts.fct_monthly_revenue` may aggregate this table to monthly grain.

### External Dependencies
- **None detected** (no API calls, external configs, or third-party systems referenced).

---

## Maintenance & Operational Notes

### Refresh Schedule
- **Frequency:** Daily (inferred from naming and use case).
- **Timing:** Typically runs post-ETL (after `stg_raw_orders` and `int_order_items` complete).
- **SLA:** Should complete within X minutes (not specified; coordinate with BI team).

### Monitoring & Alerts
- **Row count check:** Compare daily row count to baseline; sudden drops may indicate upstream data issues.
- **Null metric check:** Monitor `revenue_vs_prev_day` / `revenue_vs_prev_week` for unexpected NULLs (may indicate missing historical data).
- **Revenue validation:** Compare `gross_revenue` total to GL or source system; large discrepancies indicate data quality issues.

### Access Control
```sql
GRANT SELECT ON marts.fct_daily_revenue TO GROUP analytics_readers;
GRANT SELECT ON marts.fct_daily_revenue TO GROUP bi_team;
GRANT SELECT ON marts.fct_daily_revenue TO GROUP finance_team;
```
- **Read-only access** granted to three groups; no INSERT/UPDATE/DELETE permissions.
- **Rationale:** Prevents accidental data modification; ensures data integrity.

### Statistics & Query Optimization
```sql
ANALYZE marts.fct_daily_revenue;
```
- Runs table statistics for Redshift query planner.
- Enables optimizer to choose efficient join/scan strategies.
- Should be run after each full rebuild.

---

## Known Limitations & Future Enhancements

### Current Limitations
1. **No incremental updates:** Full table rebuild daily; inefficient for high-volume environments.
2. **No real-time data:** Daily grain only; intra-day trends not captured.
3. **Limited dimensions:** 7 dimensions may be insufficient for complex drill-downs (e.g., customer segment, product size).
4. **No fact-less fact table:** Cannot analyze combinations of dimensions without revenue (e.g., "orders with no revenue").

### Potential Enhancements
1. **Incremental materialization:** Update only changed dates (requires change data capture from upstream).
2. **Hourly grain:** Add `fct_hourly_revenue` for real-time dashboards.
3. **Additional dimensions:** Add `customer_segment`, `product_size`, `promotion_id` for richer analysis.
4. **Fact-less fact table:** Create `fct_daily_orders` (order count only) for order-level analysis independent of revenue.