# marts/dim_products.sql

## Component Overview
- **Layer:** Marts
- **Type:** Table (Redshift)
- **Schedule:** Not specified in code (infer from dbt/orchestration config)
- **Owner:** Not specified in code (infer from team documentation)

---

## Purpose

`dim_products` is a denormalized product dimension table that serves as the single source of truth for product master data combined with historical sales performance metrics. It enables BI tools and analysts to quickly answer questions about product profitability, sales velocity, customer reach, and inventory health without requiring complex joins to transactional tables. This table is optimized for dashboard queries and ad-hoc analysis where performance and ease-of-use are prioritized over storage efficiency.

---

## Inputs

- **staging.stg_raw_products** — Cleaned and validated product master data including SKU, pricing, cost, category hierarchy, supplier relationships, and current inventory levels. This component needs it to provide the authoritative product attributes and current state.

- **transforms.int_order_items** — Denormalized order line items with order metadata, customer IDs, quantities, pricing, discounts, and order status. This component needs it to calculate all historical sales performance metrics (revenue, margin, customer reach, sales trends) and to filter out invalid orders.

---

## Outputs

- **marts.dim_products** — A single denormalized table containing ~30 columns combining static product attributes with aggregated sales metrics. Consumed by:
  - BI tools (Tableau, Looker, Power BI) for product performance dashboards
  - Analysts for ad-hoc product profitability and inventory analysis
  - Potentially downstream fact tables or other mart tables requiring product context
  - Data science teams for product segmentation and recommendation models

---

## Key Business Logic

### Sales Performance Aggregation (CTE: product_sales)
The `product_sales` CTE pre-aggregates all transactional metrics at the product level from `int_order_items`. This avoids recalculating these metrics on every query and ensures consistency across all downstream consumers.

- **Filtering logic:** Excludes orders with status `'cancelled'` or `'fraud_review'` to ensure only legitimate, completed sales are counted. This prevents inflated revenue/margin figures and customer counts from being attributed to products.
- **Aggregations:** Calculates total units, revenue, margin, and order/customer counts. These are the core KPIs for product performance analysis.
- **Date range metrics:** Captures `first_sold_date` and `last_sold_date` to enable cohort analysis and identify dormant products.
- **Pricing metrics:** Averages selling price and discount percentage to understand actual realized pricing vs. list price.

### Margin Calculation (list_margin_pct)
```
(unit_price - unit_cost) / unit_price * 100
```
Calculates the gross margin percentage at list price. This is a static, policy-based margin (not actual realized margin from sales). The formula includes `NULLIF(unit_price, 0)` to prevent division-by-zero errors on free products.

### Inventory Status Classification
A business rule encoded as a CASE statement that segments products into four inventory health categories:
- **Out of Stock:** `inventory_count <= 0` — triggers urgent replenishment alerts
- **Low Stock:** `inventory_count < 10` — indicates potential stockout risk
- **Normal:** `inventory_count < 100` — healthy operational range
- **Well Stocked:** `inventory_count >= 100` — excess inventory, possible overstock

These thresholds should be reviewed with supply chain and are likely product-category-specific (a threshold of 10 units may be inappropriate for high-volume SKUs).

### Days Since Last Sale (days_since_last_sale)
```
DATEDIFF(day, last_sold_date, GETDATE())
```
Calculates how many days have elapsed since the product last appeared in an order. Products with high values (e.g., >180 days) may be candidates for discontinuation or promotional activity. Null values indicate products that have never sold.

### Revenue Quartile Segmentation (revenue_quartile)
```
NTILE(4) OVER (ORDER BY total_revenue DESC)
```
Ranks products into four equal-sized buckets (1=top 25% revenue, 4=bottom 25%) based on total historical revenue. This enables quick segmentation for "focus on top performers" analyses and ABC inventory classification.

### Null Handling Strategy
- **NVL() for sales metrics:** Products with no sales history receive 0 for units, revenue, margin, and counts. This ensures they appear in the dimension and can be analyzed as "never sold" products.
- **NVL() for avg_selling_price:** Falls back to `unit_price` (list price) if no sales exist, providing a sensible default.
- **NULLIF() for margin calculation:** Prevents division-by-zero on free products by converting 0 to NULL.
- **LEFT JOIN:** Preserves all products from `stg_raw_products` even if they have no sales history, ensuring the dimension is complete.

---

## Column Descriptions

| Column | Type | Description | Example |
|--------|------|-------------|---------|
| **product_id** | INT | Unique product identifier; primary key | 12847 |
| **sku** | VARCHAR | Stock keeping unit; human-readable product code | `WIDGET-XL-BLU-001` |
| **product_name** | VARCHAR | Marketing name of the product | `Premium Blue Widget XL` |
| **category** | VARCHAR | Top-level product category | `Hardware`, `Software`, `Services` |
| **subcategory** | VARCHAR | Secondary product classification | `Power Tools`, `Accessories` |
| **brand** | VARCHAR | Brand or manufacturer name | `Acme Corp`, `Generic` |
| **current_list_price** | DECIMAL(10,2) | Current MSRP or list price | 99.99 |
| **unit_cost** | DECIMAL(10,2) | Cost of goods sold per unit | 35.50 |
| **list_margin_pct** | DECIMAL(5,2) | Gross margin % at list price (static policy) | 64.50 |
| **inventory_count** | INT | Current on-hand inventory units | 247 |
| **inventory_status** | VARCHAR | Derived classification of stock health | `Well Stocked`, `Low Stock`, `Out of Stock` |
| **total_units_sold** | BIGINT | Cumulative units sold (excluding cancelled/fraud orders) | 15420 |
| **total_revenue** | DECIMAL(15,2) | Cumulative gross revenue from all sales | 1542000.00 |
| **total_margin** | DECIMAL(15,2) | Cumulative gross margin dollars | 856000.00 |
| **unique_customers** | INT | Count of distinct customers who purchased this product | 3847 |
| **avg_selling_price** | DECIMAL(10,2) | Average realized selling price (including discounts) | 87.50 |
| **avg_discount_given** | DECIMAL(5,2) | Average discount percentage applied at sale | 12.50 |
| **revenue_quartile** | INT | Product performance tier (1=top 25%, 4=bottom 25%) | 1, 2, 3, 4 |
| **days_since_last_sale** | INT | Days elapsed since last order containing this product | 45, NULL (if never sold) |
| **_loaded_at** | TIMESTAMP | Timestamp when this row was inserted/refreshed | 2024-01-15 03:45:22 |

---

## Data Quality & Edge Cases

### Null Handling
- **Products with no sales:** Will have `NULL` for `first_sold_date`, `last_sold_date`, and `days_since_last_sale`. All sales metrics are coerced to 0 via `NVL()`. These rows are valid and represent inventory that has never moved.
- **Free products (unit_price = 0):** The `list_margin_pct` calculation will return NULL due to `NULLIF(unit_price, 0)`. This is intentional to avoid misleading 100% margin figures.
- **Products with no cost data:** If `unit_cost` is NULL, `list_margin_pct` will be NULL. Ensure `stg_raw_products` has cost data validation.

### Deduplication Strategy
- **No explicit deduplication:** The code assumes `stg_raw_products` contains one row per product_id and `int_order_items` is already deduplicated at the line-item level. If upstream tables have duplicates, this query will produce incorrect aggregations.
- **Risk:** If `int_order_items` contains duplicate line items (e.g., from ETL failures), sales metrics will be inflated.

### Key Assumptions
1. **Product IDs are stable:** Product IDs do not change or get reused. If a product is discontinued and a new one is created with the same ID, historical metrics will be conflated.
2. **Order status values are consistent:** The filter `WHERE order_status NOT IN ('cancelled', 'fraud_review')` assumes these are the only invalid statuses. If new statuses are added (e.g., `'returned'`, `'pending'`), they will be included in metrics.
3. **Timestamps are accurate:** `GETDATE()` is used for `_loaded_at` and `days_since_last_sale` calculations. Clock skew or timezone issues could cause unexpected results.
4. **No late-arriving facts:** The query assumes all orders for a product have arrived in `int_order_items` by load time. If orders are backfilled later, metrics will be stale until the next refresh.

### Potential Breaking Changes
- **If `int_order_items` schema changes:** Removal of `quantity`, `gross_revenue`, `gross_margin`, `sold_unit_price`, `discount_pct`, `order_date`, or `order_status` columns will cause the query to fail.
- **If `stg_raw_products` schema changes:** Removal of `product_id`, `sku`, `product_name`, `category`, `subcategory`, `brand`, `unit_price`, `unit_cost`, `weight_kg`, `product_status`, `supplier_id`, `launch_date`, `last_restock_date`, or `inventory_count` will cause failures.
- **If order status values change:** New statuses (e.g., `'returned'`, `'refunded'`) will be included in sales metrics unless the filter is updated.
- **If products are soft-deleted:** If `stg_raw_products` uses a soft-delete flag, the query must be updated to filter out deleted products.

---

## Performance Notes

### Distribution & Sort Keys
- **DISTSTYLE ALL:** The entire table is replicated to all compute nodes. This is appropriate for a dimension table (typically <10M rows) because:
  - Eliminates network traffic during joins (no redistribution needed)
  - Enables efficient co-location joins with fact tables
  - Acceptable storage overhead for a dimension
  - **Risk:** If `dim_products` grows beyond 100M rows, consider switching to `DISTSTYLE KEY (product_id)` and co-distributing fact tables.

- **SORTKEY(product_id):** Rows are physically sorted by `product_id`. This optimizes:
  - Joins on `product_id` (most common join key)
  - Queries filtering by `product_id` range
  - **Trade-off:** Slows down inserts/updates; acceptable for a dimension that is typically rebuilt nightly.

### Join Strategy
- **LEFT JOIN from stg_raw_products to product_sales:** The join is on `product_id`, which is the primary key of both tables. This is an efficient equijoin.
  - **Implication:** All products from `stg_raw_products` are preserved, even if they have no sales. This is intentional.
  - **Performance:** If `product_sales` CTE is large (millions of rows), the join could be expensive. However, `product_sales` is pre-aggregated to one row per product, so it should be small.

### CTE Materialization
- **product_sales CTE:** This is a GROUP BY aggregation that reduces `int_order_items` (potentially billions of rows) to one row per product. Redshift will materialize this CTE before the outer SELECT.
  - **Cost:** The GROUP BY is the most expensive operation in this query. If `int_order_items` is very large, this could take minutes.
  - **Optimization:** Consider pre-materializing `product_sales` as a separate table if this query runs frequently and `int_order_items` is massive.

### Window Function (NTILE)
- **NTILE(4) OVER (ORDER BY total_revenue DESC):** This window function requires sorting all products by revenue. 
  - **Cost:** O(n log n) sort operation, but acceptable for a dimension table.
  - **Implication:** Products with identical revenue may be assigned different quartiles depending on sort order (non-deterministic). Consider adding a tiebreaker: `NTILE(4) OVER (ORDER BY total_revenue DESC, product_id ASC)`.

### Full Table Scan
- **No WHERE clause on outer SELECT:** The query scans all rows from `stg_raw_products`. This is necessary to include products with no sales.
- **Filtering on int_order_items:** The `WHERE order_status NOT IN (...)` filter is applied before the GROUP BY, which is efficient.

### Estimated Query Runtime
- **Typical:** 5-30 seconds (depends on size of `int_order_items`)
- **Bottleneck:** GROUP BY aggregation in `product_sales` CTE
- **Optimization opportunity:** If this runs nightly, consider materializing `product_sales` as a separate table and joining to it.

---

## Dependencies

### Upstream (Must Run Before This)
1. **staging.stg_raw_products** — Raw product data must be cleaned, validated, and loaded into staging layer. Typically sourced from:
   - ERP system (SAP, Oracle, NetSuite)
   - Product information management (PIM) system
   - Spreadsheet or API

2. **transforms.int_order_items** — Order line items must be denormalized and enriched with order metadata, customer IDs, and financial metrics. Depends on:
   - Raw orders table (fct_orders or similar)
   - Raw order line items table
   - Customer dimension
   - Product dimension (may create circular dependency if not careful)

### Downstream (Depends on This Output)
1. **BI Dashboards** — Tableau, Looker, Power BI dashboards query this table directly for product performance reporting.
2. **Fact Tables** — Other mart tables (e.g., `fct_sales`, `fct_inventory`) may join to this dimension for context.
3. **Ad-hoc Analysis** — Analysts query this table directly for product profitability, inventory, and sales analysis.
4. **Data Science Models** — Product segmentation, recommendation engines, and demand forecasting may use this table as a feature source.

### External Dependencies
- **Redshift cluster:** Query requires active Redshift cluster with sufficient compute capacity.
- **IAM permissions:** Users must have SELECT on `staging.stg_raw_products` and `transforms.int_order_items`, and CREATE on `marts` schema.
- **Group memberships:** `analytics_readers` and `bi_team` groups must exist for GRANT statements to succeed.

### Circular Dependency Risk
⚠️ **Potential Issue:** If `int_order_items` depends on `dim_products` for product attributes, and `dim_products` depends on `int_order_items` for sales metrics, a circular dependency exists. **Resolution:** Ensure `int_order_items` uses `stg_raw_products` directly for product attributes, not `dim_products`.

---

## Maintenance & Refresh Strategy

### Recommended Refresh Cadence
- **Nightly full rebuild** (DROP and CREATE) — Simplest approach; ensures no stale data.
- **Incremental updates** — If table grows very large, consider INSERT/UPDATE logic to refresh only changed products.

### Monitoring Queries
```sql
-- Check for products with no sales
SELECT COUNT(*) FROM marts.dim_products WHERE total_units_sold = 0;

-- Check for stale products (no sales in 6 months)
SELECT COUNT(*) FROM marts.dim_products WHERE days_since_last_sale > 180;

-- Check for data freshness
SELECT MAX(_loaded_at) FROM marts.dim_products;

-- Validate quartile distribution (should be ~25% each)
SELECT revenue_quartile, COUNT(*) FROM marts.dim_products GROUP BY revenue_quartile;
```

### Known Limitations
- **Slowly changing dimensions:** This table does not track historical changes to product attributes (e.g., price changes, category reassignments). If historical product state is needed, implement SCD Type 2 logic.
- **Real-time metrics:** Sales metrics are only as fresh as the last load of `int_order_items`. For real-time dashboards, query the transactional table directly.
- **Product hierarchy changes:** If a product is moved to a different category, the old category is lost. Consider adding `_valid_from` and `_valid_to` timestamps if audit trail is needed.