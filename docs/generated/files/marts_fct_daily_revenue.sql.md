# marts/fct_daily_revenue.sql

## Component Overview
- **Layer:** Marts (final consumption layer)
- **Type:** Fact table
- **Schedule:** Not specified in code; infer from orchestration metadata
- **Owner:** Not specified in code; likely Finance or Analytics Engineering team

---

## Purpose

This component aggregates transactional order data into a daily revenue summary, rolled up by product category, subcategory, brand, sales channel, country, and payment method. It serves as the single source of truth for executive dashboards, financial reporting, and revenue analytics, enabling stakeholders to track daily performance, margin trends, and channel/geographic performance without querying raw transaction tables.

---

## Inputs

| Source | Purpose | Critical Data |
|--------|---------|----------------|
| **transforms.int_order_items** | Provides line-item revenue, cost, margin, and product classification data. This component needs it to calculate gross/net revenue, COGS, margins, and product-level metrics. | `order_id`, `category`, `subcategory`, `brand`, `quantity`, `gross_revenue`, `net_revenue`, `cogs`, `gross_margin`, `is_discounted`, `product_id` |
| **staging.stg_raw_orders** | Provides order-level context: date, channel, geography, payment method, and order status. This component needs it to filter valid orders and segment revenue by business dimensions. | `order_id`, `order_date`, `order_channel`, `billing_country`, `payment_method`, `order_status`, `customer_id` |

---

## Outputs

| Target | Contents | Consumers |
|--------|----------|-----------|
| **marts.fct_daily_revenue** | Daily revenue fact table with 30+ columns spanning volume metrics (order/customer/product counts), revenue metrics (gross/net/margin), averages (AOV, unit price), discount analysis, and day-over-day/week-over-week comparisons. Grain: one row per (date, category, subcategory, brand, channel, country, payment_method) combination. | Executive dashboard, Finance team (P&L reporting), BI analysts, revenue forecasting models |

---

## Key Business Logic

### 1. **Order Status Filtering**
```
WHERE o.order_status NOT IN ('pending_payment', 'fraud_review', 'cancelled')
```
- **Why:** Only recognizes completed, shipped, or delivered orders as "revenue." Excludes orders still awaiting payment, under fraud investigation, or cancelled to prevent overstating recognized revenue.
- **Business Rule:** Aligns with revenue recognition policy (likely ASC 606 or similar).

### 2. **Revenue Metrics Calculation**
- **gross_revenue** = sum of pre-discount, pre-tax line item totals
- **net_revenue** = sum of post-discount, post-tax line item totals
- **cogs** = sum of cost of goods sold per line item
- **gross_margin** = net_revenue − cogs
- **margin_pct** = (gross_margin / gross_revenue) × 100, capped at 0 if no revenue
- **Why:** Provides multi-perspective view of profitability; gross vs. net separates discount impact; margin % is normalized for comparison across categories/channels.

### 3. **Volume Metrics**
- **order_count** = distinct order IDs (prevents double-counting if one order has multiple items)
- **customer_count** = distinct customer IDs (identifies unique buyers per day/segment)
- **units_sold** = sum of quantities (physical unit volume)
- **unique_products_sold** = distinct product IDs (breadth of assortment sold)
- **Why:** Separates order-level, customer-level, and product-level metrics for different analytical questions (e.g., "How many orders?" vs. "How many customers?" vs. "How many units?").

### 4. **Average Metrics**
- **avg_order_value** = gross_revenue / order_count (with NULLIF to prevent division by zero)
- **avg_unit_price** = gross_revenue / units_sold (with NULLIF)
- **Why:** Normalized metrics for trend analysis and channel/category comparison; NULLIF prevents errors on zero-revenue days.

### 5. **Discount Analysis**
- **discounted_revenue** = sum of gross_revenue where is_discounted = true
- **discount_revenue_pct** = (discounted_revenue / total_gross_revenue) × 100
- **Why:** Isolates impact of promotional activity; helps Finance track discount elasticity and margin erosion.

### 6. **Day-over-Day & Week-over-Week Comparisons**
```
LAG(SUM(oi.gross_revenue), 1) OVER (
    PARTITION BY oi.category, o.order_channel
    ORDER BY o.order_date
)
```
- **revenue_vs_prev_day** = today's revenue − yesterday's revenue (same category/channel)
- **revenue_vs_prev_week** = today's revenue − 7 days ago (same category/channel)
- **Why:** Enables quick trend spotting in dashboards without requiring joins to historical snapshots; window function avoids self-joins.

### 7. **Aggregation Grain**
```
GROUP BY o.order_date, oi.category, oi.subcategory, oi.brand, 
         o.order_channel, o.billing_country, o.payment_method
```
- **Why:** Creates one row per unique combination of these dimensions. Allows drill-down from high-level (total daily revenue) to granular (e.g., "Nike shoes sold via mobile in Germany via credit card on 2024-01-15").

---

## Column Descriptions

| Column | Type | Description | Example |
|--------|------|-------------|---------|
| **revenue_date** | DATE | Order date; the business day for which revenue is reported. | 2024-01-15 |
| **category** | VARCHAR | Top-level product category (e.g., Apparel, Footwear, Accessories). | Footwear |
| **subcategory** | VARCHAR | Secondary product classification. | Running Shoes |
| **brand** | VARCHAR | Product brand. | Nike |
| **order_channel** | VARCHAR | Sales channel (e.g., web, mobile, retail, marketplace). | mobile |
| **billing_country** | VARCHAR | Country of billing address (ISO 3166-1 alpha-2 or full name). | US |
| **payment_method** | VARCHAR | Payment type (e.g., credit_card, paypal, bank_transfer). | credit_card |
| **order_count** | INTEGER | Number of distinct orders placed on this date in this segment. | 1,250 |
| **customer_count** | INTEGER | Number of distinct customers who placed orders in this segment. | 980 |
| **units_sold** | INTEGER | Total quantity of items sold. | 2,100 |
| **unique_products_sold** | INTEGER | Number of distinct product SKUs sold. | 45 |
| **gross_revenue** | DECIMAL(18,2) | Total pre-discount, pre-tax revenue. | 125,000.00 |
| **net_revenue** | DECIMAL(18,2) | Total post-discount, post-tax revenue (recognized revenue). | 118,500.00 |
| **cogs** | DECIMAL(18,2) | Total cost of goods sold. | 65,000.00 |
| **gross_margin** | DECIMAL(18,2) | net_revenue − cogs. | 53,500.00 |
| **margin_pct** | DECIMAL(5,2) | Gross margin as percentage of gross revenue. | 42.80 |
| **avg_order_value** | DECIMAL(10,2) | Average revenue per order (gross_revenue / order_count). | 100.00 |
| **avg_unit_price** | DECIMAL(10,2) | Average revenue per unit sold (gross_revenue / units_sold). | 59.52 |
| **discounted_revenue** | DECIMAL(18,2) | Revenue from orders/items marked as discounted. | 18,750.00 |
| **discount_revenue_pct** | DECIMAL(5,2) | Percentage of gross revenue that was discounted. | 15.00 |
| **revenue_vs_prev_day** | DECIMAL(18,2) | Change in gross revenue vs. same segment yesterday. | +5,000.00 |
| **revenue_vs_prev_week** | DECIMAL(18,2) | Change in gross revenue vs. same segment 7 days ago. | +12,500.00 |
| **_loaded_at** | TIMESTAMP | UTC timestamp when this row was inserted (for SCD tracking). | 2024-01-16 02:30:45 |

---

## Data Quality & Edge Cases

### Null Handling
- **NULLIF in division:** `NULLIF(COUNT(DISTINCT o.order_id), 0)` and `NULLIF(SUM(oi.quantity), 0)` prevent division-by-zero errors; result is NULL if denominator is zero.
- **CASE WHEN in margin_pct:** `CASE WHEN SUM(oi.gross_revenue) > 0 THEN ... ELSE 0 END` explicitly returns 0 (not NULL) if no revenue, preventing downstream NULL propagation in dashboards.
- **LAG window functions:** If no prior day/week exists (e.g., first day of data), LAG returns NULL; dashboards should handle this gracefully.

### Deduplication Strategy
- **DISTINCT on order_id and customer_id:** Prevents double-counting if one order contains multiple line items (all items are aggregated, but order/customer counted once).
- **No explicit deduplication of product_id:** COUNT(DISTINCT product_id) counts each unique SKU once per day/segment, even if sold multiple times.

### Assumptions About Upstream Data
1. **stg_raw_orders.order_date is always populated** and represents the business date (not timestamp).
2. **int_order_items.order_id matches stg_raw_orders.order_id** (referential integrity enforced upstream).
3. **int_order_items.gross_revenue, net_revenue, cogs, gross_margin are pre-calculated** and accurate; this component does not recalculate them.
4. **is_discounted flag is reliable:** assumes upstream logic correctly identifies discounted line items.
5. **order_status values are standardized** (e.g., 'pending_payment', 'fraud_review', 'cancelled', 'shipped', 'delivered').
6. **No late-arriving facts:** assumes all line items for a given order_date are present by load time (no delayed shipments or adjustments).

### What Could Break
- **Missing order_id in stg_raw_orders:** INNER JOIN would silently drop rows from int_order_items; revenue would be undercounted.
- **Null values in grouping dimensions:** NULL category, channel, or country would create a "catch-all" row; consider adding COALESCE('Unknown') if upstream allows NULLs.
- **Duplicate order_ids in stg_raw_orders:** INNER JOIN would create a Cartesian product, inflating metrics.
- **Upstream schema changes:** If int_order_items.is_discounted is dropped or renamed, discount metrics will fail.
- **Timezone misalignment:** If order_date is stored in local time but _loaded_at is UTC, day boundaries may shift for international orders.

---

## Performance Notes

### Join Strategy
- **INNER JOIN on order_id:** Filters to only orders present in both tables. Efficient if both tables are indexed on order_id (assumed in staging/transforms layers).
- **Join selectivity:** WHERE clause filters stg_raw_orders before join, reducing join cardinality.

### Aggregation & Grouping
- **GROUP BY 7 dimensions:** Creates a relatively high-cardinality result set. For a global retailer with 10 categories, 50 subcategories, 100 brands, 5 channels, 50 countries, and 10 payment methods, this could yield millions of rows per day.
- **Window functions (LAG):** Computed after GROUP BY; relatively cheap since they operate on the aggregated result set, not raw rows.

### Distribution & Sort Keys
```
DISTKEY(revenue_date)
SORTKEY(revenue_date, category)
```
- **DISTKEY(revenue_date):** Distributes rows across Redshift nodes by date. Rationale: most queries filter by date range; co-locates same-date rows on same node, reducing network traffic.
- **SORTKEY(revenue_date, category):** Sorts within each node by date, then category. Rationale: typical queries filter by date and category; zone maps enable efficient pruning.
- **Trade-off:** Sorting by (revenue_date, category) may slow queries that filter heavily on channel or country; consider secondary sort if those are common.

### Expensive Operations
- **DISTINCT on multiple columns:** COUNT(DISTINCT o.order_id), COUNT(DISTINCT o.customer_id), COUNT(DISTINCT oi.product_id) require hash aggregation; acceptable for daily rollup but could be slow if run on raw transaction tables.
- **Window functions:** LAG requires sorting; acceptable here since result set is pre-aggregated.

### Indexing Assumptions
- Assumes upstream tables (stg_raw_orders, int_order_items) have indexes on order_id and order_date for efficient joins and filtering.

---

## Dependencies

### Upstream (Must Run Before This Component)
1. **staging.stg_raw_orders**
   - Extracts and cleanses raw order data from source systems.
   - Must populate: order_id, order_date, order_channel, billing_country, payment_method, order_status, customer_id.
   - SLA: Must complete before this component runs.

2. **transforms.int_order_items**
   - Joins raw order items with product master; calculates revenue, cost, and margin.
   - Must populate: order_id, category, subcategory, brand, quantity, gross_revenue, net_revenue, cogs, gross_margin, is_discounted, product_id.
   - SLA: Must complete before this component runs.

### Downstream (Depends on This Component's Output)
1. **Executive Dashboard** (BI tool, e.g., Tableau, Looker)
   - Queries fct_daily_revenue to display KPIs: daily revenue, margin %, AOV, channel performance.
   - Expects: daily refresh; data available by 06:00 UTC for morning standup.

2. **Finance P&L Report** (automated report or manual query)
   - Aggregates fct_daily_revenue by date and category for monthly/quarterly P&L.
   - Expects: accurate gross_revenue, net_revenue, cogs, margin_pct.

3. **Revenue Forecasting Model** (Python/R script or ML pipeline)
   - Uses historical fct_daily_revenue to train time-series models.
   - Expects: complete daily history; no gaps or retroactive corrections without notification.

4. **Channel Performance Analytics** (ad-hoc queries, BI reports)
   - Analyzes revenue_vs_prev_day, revenue_vs_prev_week by channel.
   - Expects: accurate LAG calculations; consistent dimension values.

### External Dependencies
- **Redshift cluster:** Must be online and have sufficient storage for fact table (estimated 100 GB–1 TB depending on history retention).
- **IAM roles:** analytics_readers, bi_team, finance_team groups must exist in Redshift.
- **System clock:** GETDATE() assumes Redshift system time is accurate (UTC).

---

## Maintenance & Monitoring

### Recommended Alerts
- **Row count anomaly:** Alert if daily row count drops >20% or increases >50% (indicates upstream data quality issue).
- **NULL values in key columns:** Monitor for unexpected NULLs in revenue_date, category, or gross_revenue.
- **Negative revenue:** Alert if any gross_revenue or net_revenue is negative (data quality issue or refund logic problem).
- **Load time SLA:** Alert if load time exceeds 30 minutes (performance degradation).

### Refresh Strategy
- **Full refresh recommended:** DROP TABLE + CREATE TABLE ensures no stale data; acceptable for daily batch.
- **Alternative (incremental):** If performance becomes an issue, consider INSERT-only with date-based partitioning and periodic VACUUM.

### Retention Policy
- **Suggested:** Keep 3 years of history for trend analysis; archive older data to S3 if needed.