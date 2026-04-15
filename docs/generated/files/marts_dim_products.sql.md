# marts/dim_products.sql

## Component Overview
- **Layer:** Marts
- **Type:** Table (materialized dimension)
- **Schedule:** Not specified in code; recommend daily refresh post-order processing
- **Owner:** Not specified in code; recommend Data Analytics or BI Engineering team

---

## Purpose

`dim_products` is the authoritative product dimension table consumed by BI tools and analysts for product performance analysis, inventory monitoring, and sales reporting. It enriches core product attributes (SKU, category, pricing) with aggregated sales metrics and inventory status, enabling stakeholders to answer questions like "Which products drive the most revenue?" and "What products are at risk of stockout?" without requiring real-time joins to transactional tables.

---

## Inputs

- **staging.stg_raw_products** — Provides the canonical product master data including SKU, name, category, brand, unit cost, current list price, weight, supplier relationships, launch date, and current inventory count. This component needs it to establish the product dimension's core attributes and ensure all products (sold or not) are represented.

- **transforms.int_order_items** — Provides the denormalized order line item facts including product_id, quantity, gross_revenue, gross_margin, sold_unit_price, discount_pct, order_id, customer_id, order_date, and order_status. This component needs it to calculate historical sales performance metrics (total units sold, revenue, margin, customer reach, and sales velocity).

---

## Outputs

- **marts.dim_products** — A denormalized product dimension table containing 30+ columns spanning product master data, calculated margins, sales performance aggregates, inventory status classifications, and performance tiers. Consumed by BI tools (Tableau, Looker, Power BI), analyst ad-hoc queries, and downstream fact tables requiring product context. Grants SELECT access to `analytics_readers` and `bi_team` groups.

---

## Key Business Logic

### 1. **Sales Performance Aggregation (CTE: product_sales)**
Aggregates all order line items by product, excluding cancelled and fraud_review orders. Calculates:
- **Total units sold, revenue, and margin** — Cumulative lifetime metrics for product profitability assessment
- **Order and customer counts** — Indicates market penetration and repeat purchase behavior
- **First/last sold dates** — Establishes product lifecycle stage and sales recency
- **Average selling price and discount** — Reveals actual realized pricing vs. list price, indicating promotional intensity

**Why:** Enables product managers to identify high-value products, assess promotional effectiveness, and detect slow-moving inventory.

### 2. **Margin Calculation (list_margin_pct)**
Computes `(unit_price - unit_cost) / unit_price * 100` with NULLIF protection against division by zero.

**Why:** Provides gross margin % at list price for quick profitability assessment; complements actual realized margin from sales data.

### 3. **Order Status Filtering**
Excludes `cancelled` and `fraud_review` orders from sales aggregates.

**Why:** Ensures metrics reflect only legitimate, completed transactions; prevents inflated revenue/margin figures and false customer counts.

### 4. **Inventory Status Classification**
Tiered categorization based on inventory_count:
- Out of Stock: ≤ 0
- Low Stock: < 10
- Normal: < 100
- Well Stocked: ≥ 100

**Why:** Enables supply chain teams to quickly identify replenishment urgency; supports inventory optimization workflows.

### 5. **Days Since Last Sale**
Calculates `DATEDIFF(day, last_sold_date, GETDATE())` to measure sales recency.

**Why:** Identifies dormant or slow-moving products; flags potential obsolescence or demand shifts requiring investigation.

### 6. **Revenue Quartile Ranking (revenue_quartile)**
Uses `NTILE(4) OVER (ORDER BY total_revenue DESC)` to segment products into four performance tiers (Q1 = top 25%, Q4 = bottom 25%).

**Why:** Enables Pareto analysis (80/20 rule), product portfolio segmentation, and targeted marketing/discontinuation decisions.

### 7. **Null Handling Strategy**
Uses `NVL()` to default sales metrics to 0 for products with no sales history, and defaults `avg_selling_price` to `unit_price` when no sales exist.

**Why:** Ensures new products and slow-movers appear in the dimension with sensible defaults; prevents NULL propagation in downstream analytics.

### 8. **LEFT JOIN Strategy**
Left joins `stg_raw_products` to `product_sales` CTE, ensuring all products appear even if never sold.

**Why:** Maintains a complete product universe; supports inventory and product master reporting independent of sales activity.

---

## Column Descriptions

| Column | Data Type | Description | Example Values |
|--------|-----------|-------------|-----------------|
| **product_id** | INT | Unique product identifier; primary key | 1001, 5432, 9999 |
| **sku** | VARCHAR | Stock keeping unit; human-readable product code | "WIDGET-001-BLU", "GADGET-XL" |
| **product_name** | VARCHAR | Marketing product name | "Premium Widget Pro", "Compact Gadget" |
| **category** | VARCHAR | Top-level product category | "Electronics", "Home & Garden", "Sports" |
| **subcategory** | VARCHAR | Secondary product classification | "Laptops", "Outdoor Tools", "Team Sports" |
| **brand** | VARCHAR | Manufacturer or brand name | "TechCorp", "HomeMax", "SportsPro" |
| **current_list_price** | DECIMAL(10,2) | Current MSRP or list price | 99.99, 1500.00 |
| **unit_cost** | DECIMAL(10,2) | Product cost of goods sold (COGS) | 29.99, 450.00 |
| **list_margin_pct** | DECIMAL(5,2) | Gross margin % at list price | 70.00, 45.50 |
| **inventory_count** | INT | Current on-hand inventory units | 0, 5, 250 |
| **inventory_status** | VARCHAR | Categorical stock level assessment | "Out of Stock", "Low Stock", "Normal", "Well Stocked" |
| **total_units_sold** | BIGINT | Lifetime cumulative units sold (excl. cancelled/fraud) | 0, 1500, 50000 |
| **total_revenue** | DECIMAL(15,2) | Lifetime cumulative gross revenue | 0.00, 149,850.00 |
| **total_margin** | DECIMAL(15,2) | Lifetime cumulative gross margin dollars | 0.00, 74,925.00 |
| **unique_customers** | INT | Count of distinct customers who purchased | 0, 42, 5000 |
| **avg_selling_price** | DECIMAL(10,2) | Average realized price per unit (incl. discounts) | 89.99, 1350.00 |
| **avg_discount_given** | DECIMAL(5,2) | Average discount % applied across all sales | 0.00, 15.50 |
| **days_since_last_sale** | INT | Days elapsed since most recent sale | NULL (if never sold), 0, 365 |
| **revenue_quartile** | INT | Product performance tier (1=top 25%, 4=bottom 25%) | 1, 2, 3, 4 |
| **_loaded_at** | TIMESTAMP | Table refresh timestamp (UTC) | 2024-01-15 08:30:00 |

---

## Data Quality & Edge Cases

### Null Handling
- **Sales metrics for new/unsold products:** Defaulted to 0 via `NVL()` to avoid NULL propagation in downstream calculations.
- **avg_selling_price for unsold products:** Defaults to `unit_price` (list price) as a reasonable proxy.
- **days_since_last_sale for unsold products:** Will be NULL; downstream queries should use `COALESCE(days_since_last_sale, 999999)` or similar to handle.
- **Margin calculations:** Protected against division by zero with `NULLIF(p.unit_price, 0)` to prevent errors if list price is 0.

### Deduplication Strategy
- **Product dimension:** No explicit deduplication; assumes `staging.stg_raw_products` is already deduplicated by product_id.
- **Sales aggregation:** Uses `GROUP BY product_id` to collapse all order line items into one row per product; `COUNT(DISTINCT order_id)` and `COUNT(DISTINCT customer_id)` prevent double-counting across multiple line items per order.

### Key Assumptions
1. **Product master is authoritative:** `stg_raw_products` is assumed to be the single source of truth; if a product exists in orders but not in stg_raw_products, it will not appear in this dimension.
2. **Order status values are consistent:** Code assumes order_status contains exactly "cancelled" and "fraud_review" (case-sensitive); typos or variations will not be filtered.
3. **Dates are valid:** Assumes `order_date`, `launch_date`, `last_restock_date` are valid dates; malformed dates will cause DATEDIFF to fail.
4. **Inventory count is non-negative:** Code assumes inventory_count ≥ 0 in normal cases; negative inventory (overselling) is treated as "Out of Stock."
5. **No product ID collisions:** Assumes product_id is globally unique across stg_raw_products and int_order_items.

### What Could Break
- **Upstream schema changes:** If `int_order_items` removes `gross_revenue`, `gross_margin`, or `sold_unit_price` columns, the CTE will fail.
- **New order statuses:** If new order statuses are introduced (e.g., "pending", "returned"), they will be included in sales metrics unless the WHERE clause is updated.
- **Timezone issues:** `GETDATE()` returns server time; if servers span timezones, `_loaded_at` may be inconsistent.
- **Inventory going negative:** If inventory_count can be negative (overselling), the inventory_status logic may misclassify products.
- **Duplicate products in stg_raw_products:** If product master has duplicates, LEFT JOIN will create multiple rows per product in output.
- **Missing product_id in orders:** If int_order_items contains NULL or invalid product_ids, they will be excluded from sales aggregates, creating a blind spot.

---

## Performance Notes

### Join Strategy
- **LEFT JOIN from stg_raw_products to product_sales CTE:** Ensures all products appear even if unsold. The CTE is pre-aggregated, so the join is efficient (product_id to product_id on small cardinality).
- **Implicit join cardinality:** Assuming ~10K-100K products and millions of order line items, the CTE aggregation reduces int_order_items to product-level grain before joining, avoiding a large intermediate result set.

### Distribution & Sorting
- **DISTSTYLE ALL:** Replicates the entire table to all nodes. Appropriate for a dimension table (typically <100M rows) that is frequently joined; avoids network traffic during joins.
- **SORTKEY(product_id):** Sorts on product_id to optimize lookups and joins on this column; improves query performance for product-level filters and joins in downstream queries.

### Expensive Operations
- **CTE aggregation (product_sales):** Scans the entire `int_order_items` table and groups by product_id. If int_order_items is very large (billions of rows), this could be slow. Consider materializing this as an intermediate table if refresh time becomes an issue.
- **NTILE window function:** Requires a full sort of the result set by total_revenue; O(n log n) complexity but acceptable for dimension tables.
- **DATEDIFF calculation:** Computed for every row; minimal cost but adds slight overhead.

### Optimization Opportunities
1. **Materialize product_sales as a separate table** if int_order_items is extremely large and refresh time is critical.
2. **Add indexes on product_id** in stg_raw_products and int_order_items if not already present.
3. **Consider incremental refresh** if the table grows beyond 500M rows; currently uses DROP TABLE + CREATE, which is a full rebuild.
4. **Partition by category or brand** if queries frequently filter on these dimensions (not currently done).

---

## Dependencies

### Upstream (Must Run Before This Component)
1. **staging.stg_raw_products** — Raw product master data must be loaded and deduplicated.
2. **transforms.int_order_items** — Denormalized order line items must be transformed and aggregated; typically depends on:
   - Raw orders table
   - Raw order items table
   - Raw products table (for enrichment)
   - Potentially customer and date dimensions

### Downstream (Components That Depend on This Output)
1. **BI Tools & Dashboards** — Tableau, Looker, Power BI dashboards query this table directly for product performance reporting.
2. **Fact Tables** — Any fact tables requiring product context (e.g., `fct_sales`, `fct_inventory`) may join to this dimension.
3. **Ad-Hoc Analyst Queries** — Analysts use this table for product profitability, portfolio analysis, and inventory optimization.
4. **Data Marts** — Other mart tables may depend on product classifications (category, brand, quartile) from this dimension.
5. **Reporting Views** — Curated views for specific business functions (e.g., product performance scorecard) likely build on top of this table.

### External Dependencies
- **Redshift cluster & schema permissions:** Requires `CREATE TABLE` on `marts` schema and `SELECT` on `staging` and `transforms` schemas.
- **IAM/Access Control:** Depends on `analytics_readers` and `bi_team` groups existing in Redshift; GRANT statements will fail if groups don't exist.
- **System clock:** `GETDATE()` depends on Redshift server time; ensure server time is synchronized.

---

## Maintenance & Monitoring Recommendations

- **Refresh frequency:** Daily after order processing completes (recommend post-midnight batch window).
- **Data quality checks:** Monitor for NULL values in critical columns (product_id, sku), verify revenue_quartile distribution is balanced, and alert if days_since_last_sale exceeds 180 days for high-revenue products.
- **Performance monitoring:** Track query execution time; if refresh time exceeds 30 minutes, consider materializing the product_sales CTE.
- **Access audit:** Periodically review GRANT statements to ensure only intended groups have SELECT access.