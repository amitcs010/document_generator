# marts/dim_products.sql

## Component Overview
- **Layer:** Marts
- **Type:** Table (Redshift)
- **Schedule:** Not specified in code (infer from orchestration layer)
- **Owner:** Not specified in code (infer from team documentation)

---

## Purpose

`dim_products` is a denormalized product dimension table that serves as the single source of truth for product master data combined with historical sales performance metrics. It enables BI tools and analysts to quickly answer questions about product profitability, sales velocity, customer reach, and inventory health without requiring complex joins to transactional tables. This table is optimized for dashboard queries and ad-hoc analysis where performance and ease of use are prioritized over storage efficiency.

---

## Inputs

- **staging.stg_raw_products** — The cleaned, deduplicated product master data containing current product attributes (SKU, name, category, pricing, cost, weight, supplier relationships, inventory levels, and lifecycle dates). This component needs it to provide the authoritative product reference data and current operational attributes.

- **transforms.int_order_items** — The conformed order line items fact table containing historical transaction-level data (order IDs, customer IDs, quantities, revenue, margins, discounts, order dates, and order status). This component needs it to calculate cumulative sales performance metrics and customer reach for each product.

---

## Outputs

- **marts.dim_products** — A denormalized product dimension table consumed by BI tools (Tableau, Looker, etc.), analytics teams, and business stakeholders. Contains 30+ columns combining static product attributes with aggregated sales metrics, inventory status classifications, and performance rankings. Used for product performance dashboards, inventory management reports, sales analysis, and product lifecycle tracking.

---

## Key Business Logic

### 1. **Sales Performance Aggregation (CTE: product_sales)**
Aggregates historical order data at the product level, excluding cancelled and fraud-flagged orders to ensure only legitimate sales are counted. Calculates:
- **Total units sold & revenue** — Cumulative volume and value metrics for product performance assessment
- **Gross margin** — Actual profit contribution (not just list margin) based on what customers actually paid
- **Order and customer counts** — Breadth of market adoption and customer base size
- **Date range (first/last sold)** — Product lifecycle visibility and sales recency
- **Average selling price & discount** — Actual realized pricing vs. list price, revealing discount patterns

**Why:** Provides a single, pre-aggregated view of product performance to avoid expensive GROUP BY operations on large fact tables during dashboard queries.

### 2. **Margin Calculation (list_margin_pct)**
Computes theoretical margin percentage at list price: `(unit_price - unit_cost) / unit_price * 100`

**Why:** Distinguishes between list margin (what the product *should* earn) and actual margin (what it *does* earn after discounts). Enables margin analysis and pricing strategy review.

**Edge case:** Uses `NULLIF(unit_price, 0)` to prevent division by zero for free products.

### 3. **Inventory Status Classification**
Categorizes current inventory into four business-meaningful tiers:
- **Out of Stock** (≤0) — Immediate action needed; lost sales risk
- **Low Stock** (<10) — Reorder threshold; supply chain alert
- **Normal** (<100) — Healthy operational range
- **Well Stocked** (≥100) — Excess inventory; potential write-off risk

**Why:** Enables inventory managers to quickly identify products requiring action without writing custom WHERE clauses.

### 4. **Sales Recency (days_since_last_sale)**
Calculates days elapsed since the product's most recent sale: `DATEDIFF(day, last_sold_date, GETDATE())`

**Why:** Identifies slow-moving or discontinued products. High values indicate potential obsolescence, dead stock, or seasonal dormancy.

**Edge case:** Products with no sales history will have NULL `last_sold_date`, resulting in NULL for this column (see Data Quality section).

### 5. **Revenue Quartile Ranking (revenue_quartile)**
Uses `NTILE(4)` window function to rank products into four equal-sized groups by total revenue (descending):
- **Quartile 1** — Top 25% revenue generators (strategic focus products)
- **Quartile 4** — Bottom 25% revenue generators (candidates for discontinuation)

**Why:** Enables Pareto analysis and portfolio segmentation without requiring analysts to compute percentiles themselves. Supports "focus on top performers" business strategies.

### 6. **Left Join Strategy**
Products with no sales history (new products, never-ordered SKUs) are retained with NULL sales metrics, which are coalesced to 0 or list price using `NVL()`.

**Why:** Ensures all active products appear in the dimension, even if they haven't sold yet. Prevents gaps in product catalogs and enables tracking of new product adoption.

### 7. **Null Handling Pattern**
Consistently uses `NVL(column, default)` for sales metrics:
- Sales counts → 0 (no sales = zero revenue)
- Prices → `p.unit_price` (fallback to list price if no sales history)
- Dates → NULL (preserved to indicate "never sold")

**Why:** Ensures numeric columns are never NULL (safe for SUM/AVG aggregations downstream), while preserving NULL semantics for date columns to distinguish "never sold" from "sold on [date]".

---

## Column Descriptions

| Column | Type | Description | Example Values |
|--------|------|-------------|-----------------|
| **product_id** | INT | Unique product identifier; primary key. | 1001, 5432, 9999 |
| **sku** | VARCHAR | Stock Keeping Unit; human-readable product code. | "WIDGET-BLU-LG", "GADGET-RED-SM" |
| **product_name** | VARCHAR | Marketing name of the product. | "Premium Blue Widget Large", "Standard Red Gadget" |
| **category** | VARCHAR | Top-level product classification. | "Electronics", "Home & Garden", "Sports" |
| **subcategory** | VARCHAR | Secondary product classification. | "Smartphones", "Outdoor Tools", "Team Sports" |
| **brand** | VARCHAR | Manufacturer or brand name. | "TechCorp", "HomeMax", "SportsPro" |
| **current_list_price** | DECIMAL(10,2) | Current active selling price (from stg_raw_products). | 29.99, 149.50, 1299.00 |
| **unit_cost** | DECIMAL(10,2) | Cost of goods sold per unit. | 12.00, 45.75, 500.00 |
| **list_margin_pct** | DECIMAL(5,2) | Theoretical profit margin at list price (%). | 60.00, 69.50, 61.50 |
| **inventory_count** | INT | Current on-hand inventory units. | 0, 45, 250 |
| **inventory_status** | VARCHAR | Derived classification of inventory health. | "Out of Stock", "Low Stock", "Normal", "Well Stocked" |
| **total_units_sold** | BIGINT | Cumulative units sold (excluding cancelled/fraud orders). | 0, 1250, 45000 |
| **total_revenue** | DECIMAL(15,2) | Cumulative gross revenue from all sales. | 0.00, 37500.00, 1200000.00 |
| **total_margin** | DECIMAL(15,2) | Cumulative gross profit (revenue − cost of goods). | 0.00, 15000.00, 480000.00 |
| **unique_customers** | INT | Count of distinct customers who purchased this product. | 0, 125, 3500 |
| **revenue_quartile** | INT | Product's ranking tier by total revenue (1=top, 4=bottom). | 1, 2, 3, 4 |
| **days_since_last_sale** | INT | Days elapsed since most recent sale (NULL if never sold). | 0, 45, 730 |
| **_loaded_at** | TIMESTAMP | ETL load timestamp; indicates freshness. | 2024-01-15 08:30:00 |

---

## Data Quality & Edge Cases

### Null Handling

| Scenario | Column(s) | Behavior | Impact |
|----------|-----------|----------|--------|
| Product never sold | `first_sold_date`, `last_sold_date`, `days_since_last_sale` | NULL | Cannot filter on "sold in last 30 days" without IS NOT NULL check |
| Product never sold | `total_units_sold`, `total_revenue`, `total_margin` | 0 (via NVL) | Appears in aggregations; safe for SUM operations |
| Product never sold | `avg_selling_price` | Falls back to `current_list_price` | Assumes list price is representative; may mislead if product is heavily discounted when sold |
| Free product (unit_price = 0) | `list_margin_pct` | NULL (NULLIF prevents division by zero) | Cannot calculate margin for free items; consider business rule |
| Cancelled/fraud orders | All sales metrics | Excluded from CTE WHERE clause | Prevents inflated metrics; assumes order_status is reliable |

### Deduplication Strategy

- **Product level:** `stg_raw_products` is assumed to be deduplicated at the staging layer (one row per product_id). If duplicates exist upstream, the LEFT JOIN will produce multiple rows per product.
- **Sales aggregation:** GROUP BY product_id in the CTE ensures one row per product in `product_sales`, preventing metric duplication.
- **No deduplication of order_items:** If `transforms.int_order_items` contains duplicate line items (e.g., same order_id + product_id appearing twice), metrics will be inflated. Assumes upstream conformation layer handles this.

### Key Assumptions

1. **Order status is reliable:** Filtering on `order_status NOT IN ('cancelled', 'fraud_review')` assumes this column accurately reflects transaction legitimacy. If status is updated retroactively, historical metrics won't recalculate.

2. **Product attributes are current:** `stg_raw_products` is treated as a snapshot of *current* state. Historical pricing, cost, or category changes are not tracked. If a product's category changed, this table shows only the current category.

3. **Inventory count is point-in-time:** `inventory_count` reflects stock at the time of the staging load, not a historical time series. Cannot answer "what was inventory on [past date]?"

4. **Sales dates are accurate:** `order_date` is assumed to be the true transaction date. If order dates are backdated or corrected, `first_sold_date` and `last_sold_date` may be misleading.

5. **No product merges/splits:** Assumes product_id is immutable. If products are merged (old SKU → new SKU), historical sales remain attributed to the old product_id.

### What Could Break

- **Upstream schema changes:** If `transforms.int_order_items` adds/removes columns or renames `order_status`, the CTE will fail.
- **NULL explosion in stg_raw_products:** If product master data becomes sparse (many NULLs in category, brand, etc.), downstream BI tools may filter unexpectedly.
- **Duplicate products in staging:** If `stg_raw_products` is not deduplicated, the LEFT JOIN produces Cartesian product (one product_id × N duplicates = N rows in output).
- **Extreme discount scenarios:** If `avg_discount_given` approaches 100%, `avg_selling_price` may be near zero, distorting margin analysis.
- **Date column type mismatches:** If `order_date` or `last_restock_date` are stored as strings, DATEDIFF and date comparisons will fail.

---

## Performance Notes

### Join Strategy

**LEFT JOIN from stg_raw_products to product_sales:**
- **Type:** Hash join (Redshift default for LEFT JOIN on non-indexed columns)
- **Implication:** Requires full scan of both tables; no index lookup possible
- **Optimization:** `product_id` is the join key; ensure it's indexed in both source tables
- **Cardinality:** 1:1 (one product → one sales row); no row explosion risk

### Full Table Scans

- **stg_raw_products:** Full scan required (no WHERE clause filtering)
- **transforms.int_order_items (in CTE):** Full scan with WHERE filter on `order_status`; the filter reduces rows before GROUP BY but doesn't eliminate the scan

### Expensive Operations

- **NTILE window function:** Requires sorting all products by revenue; O(n log n) complexity. Acceptable for product dimensions (typically 10K–100K rows) but would be expensive on fact tables.
- **COUNT(DISTINCT customer_id):** Requires deduplication of customer_id values per product; moderately expensive but necessary for customer reach metrics.

### Distribution & Sort Keys

```sql
DISTSTYLE ALL
SORTKEY(product_id)
```

- **DISTSTYLE ALL:** Entire table is replicated to all compute nodes. 
  - **Why:** Product dimension is small (typically <100K rows) and accessed by all queries; replication avoids network shuffles during joins.
  - **Trade-off:** Uses more disk space on each node but eliminates distribution overhead.

- **SORTKEY(product_id):** Rows are physically sorted by product_id.
  - **Why:** Most queries filter or join on product_id; sort key enables zone map pruning and faster lookups.
  - **Alternative:** Could use `SORTKEY(revenue_quartile, product_id)` if quartile-based filtering is common, but product_id is the most selective.

### Estimated Row Count & Storage

- **Typical product catalog:** 10K–100K products
- **Columns:** 30+ (mix of VARCHAR, INT, DECIMAL, TIMESTAMP)
- **Estimated size:** 100 MB – 1 GB (uncompressed); Redshift compression typically reduces to 20–30 MB
- **Query performance:** Typical dashboard query (filter + aggregate) should complete in <1 second

### Refresh Frequency Implications

- **Full table DROP/CREATE:** Rebuilds entire table; no incremental updates. Suitable for daily or weekly refreshes.
- **Alternative:** Could use UPSERT (DELETE + INSERT) if incremental updates are needed, but current approach is simpler and sufficient for batch ETL.

---

## Dependencies

### Upstream (Must Run Before This Component)

1. **staging.stg_raw_products**
   - Dependency type: Data source
   - Frequency: Typically refreshed daily or on-demand
   - Failure impact: If stg_raw_products is stale or missing, dim_products will reflect outdated product attributes (pricing, inventory, categories)

2. **transforms.int_order_items**
   - Dependency type: Data source
   - Frequency: Typically refreshed daily (after order transactions are finalized)
   - Failure impact: If int_order_items is missing or incomplete, sales metrics will be underreported; new products may show zero sales even if they've been ordered

3. **Implicit: Raw source tables for staging layer**
   - `raw.products` (or equivalent) → `staging.stg_raw_products`
   - `raw.orders`, `raw.order_items` (or equivalent) → `transforms.int_order_items`
   - Failure impact: Cascades to staging, then to this component

### Downstream (Components That Depend on This Output)

1. **BI Tools & Dashboards**
   - Tableau, Looker, Power BI dashboards querying `marts.dim_products` directly
   - Failure impact: Dashboards show stale or missing product data; business decisions delayed

2. **Analytics Queries & Reports**
   - Ad-hoc SQL queries from analysts joining `marts.dim_products` with fact tables
   - Failure impact: Analysts must write custom product lookups; slower analysis

3. **Downstream Mart Tables** (if any)
   - E.g., `marts.fct_product_performance` (if it exists) may join to dim_products
   - Failure impact: Dependent marts fail or show incomplete data

4. **Data Exports & APIs**
   - Product catalogs exported to e-commerce platforms, mobile apps, or third-party systems
   - Failure impact: External systems receive stale product data (pricing, inventory, categories)

### External Dependencies

- **Redshift cluster availability:** Table creation requires active Redshift cluster
- **IAM/permissions:** `GRANT SELECT` statements require `analytics_readers` and `bi_team` groups to exist
- **System clock:** `GETDATE()` depends on Redshift server time; time skew could cause `_loaded_at` to be inaccurate

---

## Maintenance & Monitoring Checklist

- [ ] Verify `stg_raw_products` and `int_order_items` are refreshed before running this component
- [ ] Monitor `_loaded_at` timestamp to detect stale data (should be recent)
- [ ] Check for NULL explosion in `first_sold_date` / `last_sold_date` (indicates upstream data quality issues)
- [ ] Validate `revenue_quartile` distribution (should be roughly 25% per quartile)
- [ ] Monitor table size growth; if >2 GB, consider archiving historical products
- [ ] Test edge cases: products with zero cost, free products, products with no sales
- [ ] Verify permissions after cluster maintenance (GRANT statements may need re-running)