# marts/dim_products.sql

## Component Overview
- **Layer:** Marts
- **Type:** Table (Redshift)
- **Schedule:** Not specified in code (infer from orchestration layer)
- **Owner:** Not specified in code (recommend adding as comment)

---

## Purpose

`dim_products` is a denormalized product dimension table that serves as the single source of truth for product master data and sales performance metrics across the BI platform. It combines static product attributes (SKU, category, pricing) with aggregated historical sales performance (revenue, units sold, customer reach) to enable analysts and BI tools to quickly answer questions like "Which products are our top revenue generators?" and "Which products have inventory issues?" without requiring complex joins to transactional tables.

---

## Inputs

| Source | Purpose | Why Needed |
|--------|---------|-----------|
| **staging.stg_raw_products** | Master product catalog with static attributes (name, category, brand, cost, current inventory, supplier info, launch date) | Provides the authoritative product dimension; all products in the warehouse must be represented here, even if they have no sales history |
| **transforms.int_order_items** | Denormalized order line items with quantity, revenue, margin, discount, and order metadata (order_id, customer_id, order_date, order_status) | Enables aggregation of sales performance metrics (total revenue, units sold, customer count, date ranges) to enrich the product dimension with business context |

---

## Outputs

| Target | Contents | Downstream Consumers |
|--------|----------|---------------------|
| **marts.dim_products** | Denormalized product dimension with 30+ columns including product attributes, pricing, inventory status, and aggregated sales KPIs | BI tools (Tableau, Looker, Power BI), analyst ad-hoc queries, fact tables that need product context, executive dashboards, product performance reports |

---

## Key Business Logic

### 1. **Sales Performance Aggregation (CTE: product_sales)**
Aggregates historical order-level data into product-level KPIs. Filters out cancelled and fraud_review orders to ensure only legitimate sales are counted. This prevents inflated revenue/unit metrics and ensures financial accuracy.

**Metrics calculated:**
- `total_units_sold` — cumulative quantity across all valid orders
- `total_revenue` — sum of gross revenue (price × quantity)
- `total_margin` — sum of gross profit dollars
- `order_count` — distinct orders containing the product (measures market penetration)
- `customer_count` — distinct customers who purchased (measures customer reach)
- `first_sold_date` / `last_sold_date` — product lifecycle dates (identifies new vs. mature products)
- `avg_selling_price` — average realized price after discounts (detects pricing pressure)
- `avg_discount_given` — average discount % applied (identifies promotional intensity)

### 2. **Left Join Strategy**
Products are left-joined to sales metrics, ensuring **all products appear in the dimension even if they have zero sales history**. This is critical for:
- New products not yet sold
- Discontinued products with no recent sales
- Inventory planning for non-selling SKUs

Null sales metrics are coalesced to 0 (except `avg_selling_price`, which defaults to `current_list_price` if no sales exist).

### 3. **Margin Calculation**
```
list_margin_pct = (unit_price - unit_cost) / unit_price * 100
```
Calculated from current list price and cost, representing the theoretical margin if products sold at list price. Compared against `avg_discount_given` to identify products where discounting erodes profitability.

### 4. **Inventory Status Classification**
Categorical segmentation based on current inventory count:
- **Out of Stock** (≤0) — immediate replenishment needed
- **Low Stock** (<10) — risk of stockouts
- **Normal** (<100) — healthy operational level
- **Well Stocked** (≥100) — excess inventory or high-demand buffer

Thresholds are business rules; adjust based on product velocity and lead times.

### 5. **Days Since Last Sale**
```
days_since_last_sale = DATEDIFF(day, last_sold_date, GETDATE())
```
Identifies slow-moving or obsolete inventory. Products with high `days_since_last_sale` and high `inventory_count` are candidates for clearance or discontinuation.

### 6. **Revenue Quartile Ranking**
```
revenue_quartile = NTILE(4) OVER (ORDER BY total_revenue DESC)
```
Segments products into performance tiers (Q1 = top 25% by revenue, Q4 = bottom 25%). Enables quick filtering for "top-tier products" in dashboards and supports ABC inventory analysis.

---

## Column Descriptions

| Column | Type | Description | Example |
|--------|------|-------------|---------|
| **product_id** | INT | Unique product identifier; primary key | 12847 |
| **sku** | VARCHAR | Stock keeping unit; human-readable product code | SKU-2024-001-BLK |
| **product_name** | VARCHAR | Marketing product name | "Wireless Noise-Cancelling Headphones Pro" |
| **category** | VARCHAR | Top-level product category | "Electronics" |
| **subcategory** | VARCHAR | Secondary product classification | "Audio Equipment" |
| **brand** | VARCHAR | Manufacturer/brand name | "TechBrand Inc." |
| **current_list_price** | DECIMAL(10,2) | Current MSRP or list price | 199.99 |
| **unit_cost** | DECIMAL(10,2) | Product cost of goods sold (COGS) | 89.50 |
| **list_margin_pct** | DECIMAL(5,2) | Theoretical margin % at list price | 55.23 |
| **inventory_count** | INT | Current on-hand inventory units | 247 |
| **inventory_status** | VARCHAR | Categorical inventory health | "Well Stocked", "Low Stock" |
| **total_revenue** | DECIMAL(15,2) | Cumulative gross revenue from all sales | 1,245,678.50 |
| **total_units_sold** | INT | Cumulative units sold (excluding cancelled/fraud) | 8,432 |
| **unique_customers** | INT | Count of distinct customers who purchased | 3,156 |
| **avg_selling_price** | DECIMAL(10,2) | Average realized price after discounts | 147.50 |
| **revenue_quartile** | INT | Performance tier (1=top 25%, 4=bottom 25%) | 1 |
| **days_since_last_sale** | INT | Days elapsed since last order | 45 |
| **_loaded_at** | TIMESTAMP | Table refresh timestamp (UTC) | 2024-01-15 03:45:22 |

---

## Data Quality & Edge Cases

### Null Handling
| Scenario | Handling | Rationale |
|----------|----------|-----------|
| Product has no sales history | Sales metrics coalesce to 0; `avg_selling_price` defaults to `current_list_price` | Ensures dimension completeness; new/unsold products still appear; avoids misleading NULL in price fields |
| `unit_price` is 0 | `NULLIF(unit_price, 0)` prevents division by zero in margin calculation | Protects against data corruption; margin_pct will be NULL if list price is 0 (flag for data review) |
| `last_sold_date` is NULL | `days_since_last_sale` will be NULL | Correctly represents products never sold; analysts can filter `WHERE days_since_last_sale IS NULL` to find unsold inventory |
| `order_status` is NULL | Treated as valid (not filtered out) | Assumes order_status is always populated; if not, consider adding explicit NULL check in WHERE clause |

### Deduplication Strategy
- **Product level:** No deduplication needed; `stg_raw_products` is assumed to have one row per product_id
- **Sales aggregation:** `GROUP BY product_id` ensures one output row per product; `COUNT(DISTINCT order_id)` and `COUNT(DISTINCT customer_id)` prevent double-counting if a customer ordered the same product multiple times
- **Risk:** If `stg_raw_products` contains duplicate product_ids, the LEFT JOIN will create a Cartesian product; recommend adding a uniqueness check upstream

### Assumptions About Upstream Data
1. **stg_raw_products.product_id is unique** — no duplicate products
2. **int_order_items.order_status is always populated** — filtering on status values assumes complete data
3. **int_order_items.order_date is valid** — used for date range calculations; NULL dates will break `MIN/MAX` aggregations
4. **Pricing is always positive** — margin calculation assumes unit_price ≥ unit_cost; negative prices will produce nonsensical margins
5. **Inventory count is non-negative** — inventory_status logic assumes counts ≥ 0; negative inventory indicates data quality issue

### What Could Break
| Risk | Impact | Mitigation |
|------|--------|-----------|
| Duplicate product_ids in `stg_raw_products` | Cartesian product explosion; row count multiplies; metrics duplicated | Add `SELECT DISTINCT ON (product_id)` to staging layer; add uniqueness test to dbt tests |
| NULL order_dates in `int_order_items` | `MIN/MAX(order_date)` returns NULL; `DATEDIFF` fails | Add NOT NULL constraint to int_order_items; add dbt test for null dates |
| Cancelled orders not filtered | Revenue/margin metrics inflated; KPIs misrepresent actual performance | Verify `order_status` values in source; add dbt test to confirm 'cancelled' and 'fraud_review' are filtered |
| Inventory count goes negative | `inventory_status` logic breaks (negative counts don't map to categories) | Add data quality check; flag negative inventory as anomaly; consider `ABS(inventory_count)` or explicit NULL handling |
| Product cost > list price | `list_margin_pct` becomes negative; signals pricing error | Add validation: margin_pct should be between 0–100; flag negative margins for review |

---

## Performance Notes

### Distribution & Sort Strategy
```sql
DISTSTYLE ALL
SORTKEY(product_id)
```

- **DISTSTYLE ALL:** Table is replicated to all compute nodes. Rationale: `dim_products` is small (typically <100K rows) and frequently joined to large fact tables; replication eliminates network traffic during joins and enables local join execution.
- **SORTKEY(product_id):** Rows are physically sorted by product_id on disk. Rationale: Most queries filter or join on product_id; sort key enables zone map pruning and faster range scans.

**Trade-off:** ALL distribution increases storage overhead (~3–5x) but dramatically improves join performance. Acceptable for small dimensions.

### Join Strategy
```sql
LEFT JOIN product_sales ps ON p.product_id = ps.product_id
```

- **Left join:** Preserves all products from `stg_raw_products`, even unsold ones.
- **Join key:** product_id is likely indexed in both tables; join is efficient.
- **Aggregation before join:** `product_sales` CTE pre-aggregates `int_order_items` to product level, reducing join cardinality from millions of rows to thousands. This is far more efficient than joining raw order items and aggregating after.

### Expensive Operations
| Operation | Cost | Mitigation |
|-----------|------|-----------|
| `SUM(gross_revenue)`, `SUM(gross_margin)` in CTE | Scans all rows in `int_order_items` (potentially millions) | Aggregation is necessary; ensure `int_order_items` has indexes on product_id and order_status for filtering |
| `COUNT(DISTINCT order_id)`, `COUNT(DISTINCT customer_id)` | Requires deduplication; slower than simple COUNT | Necessary for business logic; acceptable cost given pre-aggregation |
| `NTILE(4) OVER (ORDER BY total_revenue DESC)` | Window function; requires sorting all products by revenue | Lightweight operation; only runs on ~100K products, not millions of rows |
| `DATEDIFF(day, last_sold_date, GETDATE())` | Scalar function called per row | Minimal cost; runs on final result set only |

### Estimated Query Performance
- **Table size:** ~50K–500K rows (depends on product catalog size)
- **Build time:** 2–10 minutes (dominated by `int_order_items` scan and aggregation)
- **Query time:** <1 second for typical BI queries (small table, replicated distribution)

---

## Dependencies

### Upstream (Must Run Before This Component)
1. **staging.stg_raw_products**
   - Loads raw product master data from source system
   - Must complete before `dim_products` build
   - Frequency: Daily or on-demand

2. **transforms.int_order_items**
   - Denormalizes order and order_items tables; calculates revenue, margin, discount
   - Must complete before `dim_products` build
   - Frequency: Daily (or same cadence as order data refresh)

3. **Raw source tables** (implied)
   - `raw.products` → `stg_raw_products`
   - `raw.orders`, `raw.order_items` → `transforms.int_order_items`

### Downstream (Depends on This Component)
1. **BI Tools & Dashboards**
   - Tableau, Looker, Power BI connect directly to `marts.dim_products`
   - Used in product performance dashboards, inventory reports, sales analysis

2. **Fact Tables** (if any)
   - `marts.fct_orders`, `marts.fct_sales` may reference `dim_products` for product context
   - Enables conformed dimensions across fact tables

3. **Analyst Queries**
   - Ad-hoc SQL queries join `dim_products` to other marts for custom analysis
   - Product segmentation, profitability analysis, inventory planning

4. **Data Exports**
   - Product master data exports to ERP, e-commerce platforms, or external systems
   - Ensures downstream systems have consistent product definitions

### External Dependencies
- **None detected** — no API calls, external configs, or system references in code
- **Implicit:** Assumes Redshift cluster is running and `analytics_readers`, `bi_team` groups exist for GRANT statements

---

## Additional Recommendations

### Code Improvements
1. **Add explicit column comments** — Redshift supports `COMMENT ON COLUMN` for self-documenting schema
2. **Add data quality tests** — dbt tests for:
   - `product_id` uniqueness
   - `current_list_price` > 0
   - `list_margin_pct` between 0–100
   - No NULL product_names
3. **Document threshold values** — Inventory status thresholds (0, 10, 100) should be configurable or documented as business rules
4. **Add owner/SLA comment** — Include `-- Owner: Product Analytics Team` and `-- SLA: Refresh by 6 AM UTC`

### Monitoring
- Track row count over time (should be stable unless product catalog grows)
- Monitor build time; alert if >15 minutes (indicates upstream data growth or performance regression)
- Validate `days_since_last_sale` distribution; spike in high values may indicate demand drop