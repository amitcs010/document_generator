# transforms/int_order_items.sql

## Component Overview
- **Layer:** Transforms
- **Type:** Table (materialized)
- **Schedule:** Not specified in code; infer from orchestration layer
- **Owner:** Not specified in code; recommend adding as comment

---

## Purpose

This component enriches raw order line items with product master data and order context to create a single source of truth for item-level financial metrics. It computes revenue, cost of goods sold (COGS), and margin at the order-item grain, enabling downstream analytics on product profitability, discount impact, and channel performance. This table is the foundation for revenue reporting, margin analysis, and product-level dashboards consumed by Finance, Product, and Sales teams.

---

## Inputs

| Source | Purpose | Criticality |
|--------|---------|-------------|
| **spectrum.raw_order_items** | Raw order line items containing quantity, unit price, discount, and line totals. This component needs it to access the transactional detail of what was sold. | Critical |
| **staging.stg_raw_orders** | Staged order headers containing customer ID, order date, status, channel, country, and payment method. This component needs it to contextualize each line item with order-level attributes and customer identity. | Critical |
| **staging.stg_raw_products** | Staged product master containing SKU, name, category, brand, and unit cost. This component needs it to attach product taxonomy and cost data required for margin calculations. | Critical (left join; tolerates missing products) |

---

## Outputs

| Target | Contents | Downstream Consumers |
|--------|----------|---------------------|
| **transforms.int_order_items** | Denormalized order-item grain table with 20+ columns including order context, product attributes, and computed financial metrics (revenue, COGS, margin). Grain: one row per order line item. | `mart_revenue` (Finance), `mart_product_performance` (Product), BI dashboards, ad-hoc revenue queries, margin analysis reports |

---

## Key Business Logic

### 1. **Order Item Validation & Casting**
- **What:** Filters to `order_id IS NOT NULL` and `quantity > 0`; casts all numeric fields to appropriate types (BIGINT for IDs, DECIMAL for money).
- **Why:** Eliminates orphaned or voided line items; ensures numeric precision for financial calculations. Casting prevents downstream type coercion errors.

### 2. **Revenue Metrics Calculation**
- **Gross Revenue:** `line_total` as-is (before discount application).
- **Net Revenue:** `line_total * (1 - discount_pct / 100)` — applies discount percentage to compute actual revenue recognized.
- **Why:** Gross revenue shows list value; net revenue shows actual cash/accrual value. Finance needs both for variance analysis.

### 3. **Cost of Goods Sold (COGS) & Margin**
- **COGS:** `quantity * unit_cost` — multiplies units sold by product cost.
- **Gross Margin (absolute):** `line_total - COGS` — dollar profit before operating expenses.
- **Margin %:** `(line_total - COGS) / line_total * 100` — normalized profitability; capped at 0 if line_total ≤ 0.
- **Why:** Margin % enables cross-product and cross-channel profitability comparison. The zero-check prevents division errors on zero/negative line totals (e.g., returns, adjustments).

### 4. **Discount & Product Status Flags**
- **is_discounted:** Boolean flag set to TRUE if `discount_pct > 0`.
- **is_discontinued_product:** Boolean flag set to TRUE if product status is 'Discontinued'.
- **Why:** Enables fast filtering in downstream queries (e.g., "revenue from active products only") and supports discount impact analysis without string comparisons.

### 5. **Join Strategy**
- **Order Items → Orders:** INNER JOIN on `order_id` — enforces that every line item must have a valid parent order. Eliminates orphaned items.
- **Order Items → Products:** LEFT JOIN on `product_id` — tolerates missing product master records (e.g., deleted SKUs). Null unit_cost is handled with `NVL(p.unit_cost, 0)`, treating missing costs as zero (conservative margin assumption).
- **Why:** INNER join on orders ensures data integrity; LEFT join on products allows historical analysis of discontinued items without losing order data.

### 6. **Null Handling**
- `NVL(oi.discount_pct, 0)` — treats missing discounts as 0% (no discount).
- `NVL(p.unit_cost, 0)` — treats missing product costs as $0 (conservative; inflates margin).
- **Why:** Prevents NULL propagation in arithmetic; simplifies downstream logic. Conservative cost assumption avoids overstating profitability.

---

## Column Descriptions

| Column | Type | Description | Example |
|--------|------|-------------|---------|
| **order_item_id** | BIGINT | Unique identifier for this line item. Primary key. | 987654321 |
| **order_id** | BIGINT | Foreign key to the parent order. Used for aggregation and joins. | 123456 |
| **product_id** | BIGINT | Foreign key to the product master. | 5001 |
| **customer_id** | BIGINT | Customer who placed the order. Enables customer-level rollups. | 789 |
| **order_date** | DATE | Date the order was placed. Used for time-series analysis and period filtering. | 2024-01-15 |
| **order_status** | VARCHAR | Status of the parent order (e.g., 'Completed', 'Cancelled', 'Pending'). Filters for recognized revenue. | Completed |
| **order_channel** | VARCHAR | Sales channel (e.g., 'Web', 'Mobile', 'Retail', 'B2B'). Enables channel performance analysis. | Web |
| **sku** | VARCHAR | Stock keeping unit; human-readable product identifier. | SKU-12345 |
| **product_name** | VARCHAR | Marketing name of the product. | Wireless Headphones Pro |
| **category** | VARCHAR | Product category for taxonomy rollups. | Electronics |
| **quantity** | INT | Number of units sold in this line item. | 2 |
| **sold_unit_price** | DECIMAL(10,2) | Price per unit at time of sale (before discount). | 99.99 |
| **discount_pct** | DECIMAL(5,2) | Discount percentage applied to this line item. | 10.00 |
| **net_revenue** | DECIMAL(12,2) | Revenue after discount: `line_total * (1 - discount_pct / 100)`. Used for revenue recognition. | 179.98 |
| **gross_margin** | DECIMAL(12,2) | Profit in dollars: `net_revenue - COGS`. | 89.99 |
| **margin_pct** | DECIMAL(5,2) | Profitability as percentage: `gross_margin / line_total * 100`. Enables cross-product comparison. | 33.33 |
| **is_discounted** | BOOLEAN | Flag indicating if any discount was applied. Simplifies filtering. | true |
| **_loaded_at** | TIMESTAMP | Timestamp when this row was loaded into the table. Supports SCD Type 2 and audit trails. | 2024-01-16 14:32:00 |

---

## Data Quality & Edge Cases

### Null Handling
- **discount_pct:** Treated as 0% (no discount). Risk: if NULL means "unknown discount," margin is overstated.
- **unit_cost:** Treated as $0. Risk: if NULL means "cost not yet loaded," margin is overstated. **Recommendation:** Add data quality check upstream to flag missing costs.
- **product_id:** LEFT join allows NULL product attributes. Risk: downstream queries must handle NULL product names/categories. **Recommendation:** Add NOT NULL constraint or filter in downstream marts.

### Deduplication
- **No explicit deduplication.** Assumes `spectrum.raw_order_items` is already deduplicated at the order_item_id grain.
- **Risk:** If raw_order_items contains duplicates (e.g., from failed ETL retries), this table will too, inflating revenue. **Recommendation:** Add `SELECT DISTINCT` or enforce uniqueness constraint upstream.

### Filtering Logic
- **Excludes:** `order_id IS NULL` (orphaned items), `quantity ≤ 0` (returns, adjustments, voids).
- **Risk:** Negative quantities (returns) are filtered out entirely. If business requires return tracking, this logic must change. **Recommendation:** Clarify whether returns should be included as negative line items or excluded.

### Assumptions About Upstream Data
1. **order_id uniqueness:** Assumes each order_id in `stg_raw_orders` is unique. If duplicates exist, this join will create Cartesian product.
2. **product_id stability:** Assumes product_id is immutable. If products are reused or reassigned, historical analysis breaks.
3. **line_total accuracy:** Assumes `line_total = quantity * sold_unit_price * (1 - discount_pct / 100)`. If line_total is pre-calculated and doesn't match this formula, margin calculations are wrong.
4. **unit_cost currency:** Assumes `unit_cost` is in the same currency as `sold_unit_price`. If multi-currency, margin is incorrect.

### What Could Break
- **Upstream schema changes:** If `raw_order_items` drops the `discount_pct` column, this query fails.
- **Product master lag:** If a product is deleted from `stg_raw_products` before orders referencing it are loaded, those items will have NULL product attributes (acceptable due to LEFT join, but may surprise users).
- **Negative line totals:** If `line_total` is negative (e.g., refund), `margin_pct` calculation includes the zero-check, but `gross_margin` will be negative (correct). However, downstream aggregations may not handle negative margins correctly.
- **Discount > 100%:** If `discount_pct > 100`, net_revenue becomes negative. No validation prevents this.

---

## Performance Notes

### Join Strategy & Implications
| Join | Type | Cardinality | Performance Impact |
|------|------|-------------|-------------------|
| order_items → orders | INNER | Many-to-one | Eliminates orphaned items; reduces row count. Fast due to order_id indexing in staging layer. |
| order_items → products | LEFT | Many-to-one | Preserves all order items even if product missing. Slightly slower than INNER due to NULL handling, but acceptable. |

### Distribution & Sort Keys
- **DISTKEY(order_id):** Distributes rows across nodes by order_id. Rationale: Most downstream queries filter/group by order_id or customer_id (which is order_id-correlated). Collocates related items on same node, reducing network traffic for joins.
- **SORTKEY(order_date, order_id):** Sorts within each node by order_date (ascending), then order_id. Rationale: Enables efficient time-series queries (e.g., "revenue by month") and range scans on order_date. Secondary sort on order_id ensures deterministic ordering.

### Expensive Operations
- **CAST operations:** Minimal cost; applied to raw data before joins.
- **Arithmetic (margin calculations):** Negligible; simple multiplication/division per row.
- **LEFT JOIN on products:** Potential bottleneck if `stg_raw_products` is large and lacks indexes on product_id. **Recommendation:** Verify product_id is indexed in staging layer.

### Full Table Scans
- **spectrum.raw_order_items:** Full scan required (no WHERE clause filters on indexed column). Acceptable if table is partitioned by order_date upstream.
- **staging.stg_raw_orders:** Full scan required. Acceptable if small relative to order_items.
- **staging.stg_raw_products:** Full scan required. Acceptable if product master is small (<1M rows).

### Estimated Row Count & Size
- **Rows:** Approximately equal to `spectrum.raw_order_items` (minus filtered rows). If 100M order items, expect ~95-99M rows after filtering.
- **Size:** ~20 columns × 100M rows × ~150 bytes/row ≈ 300 GB (rough estimate). Verify with `SELECT pg_size_pretty(pg_total_relation_size('transforms.int_order_items'));`

### Optimization Opportunities
1. **Add WHERE clause on order_date:** If only recent orders are needed, filter in the CTE to reduce join cardinality.
2. **Materialize product attributes:** If `stg_raw_products` is frequently updated, consider caching in a separate dimension table to avoid LEFT join overhead.
3. **Incremental load:** Current logic is full refresh. Consider incremental load (INSERT only new order_items) if table grows beyond 500M rows.

---

## Dependencies

### Upstream (Must Run Before This Component)
| Component | Purpose | Frequency |
|-----------|---------|-----------|
| **spectrum.raw_order_items** (ingest) | Loads raw order line items from source system (e.g., e-commerce platform). | Daily or real-time |
| **staging.stg_raw_orders** (transform) | Stages and cleans order headers; must complete before this component joins. | Daily |
| **staging.stg_raw_products** (transform) | Stages and cleans product master; must complete before this component joins. | Daily or weekly |

### Downstream (Depends on This Component's Output)
| Component | Purpose | Frequency |
|-----------|---------|-----------|
| **mart_revenue** (mart) | Aggregates net_revenue by order_date, channel, category for Finance reporting. | Daily |
| **mart_product_performance** (mart) | Aggregates margin_pct, quantity by product, category for Product team. | Daily |
| **fct_order_items** (fact table) | Fact table for dimensional warehouse; may denormalize further. | Daily |
| **Revenue Dashboard (BI)** | Real-time dashboard showing revenue, margin, discount trends. | Real-time or hourly |
| **Margin Analysis Reports** | Ad-hoc queries on profitability by product, channel, customer segment. | On-demand |

### External Dependencies
- **None identified in code.** No API calls, external configs, or system references.
- **Implicit:** Assumes Redshift cluster is running and `analytics_readers` group exists (for GRANT statement).

### Orchestration
- **Assumed:** Airflow DAG or similar orchestrator triggers this SQL in sequence with upstream components.
- **Not specified:** Retry logic, error handling, alerting on failure.

---

## Maintenance & Monitoring

### Recommended Alerts
- **Row count anomaly:** Alert if row count drops >10% or increases >50% vs. previous day (indicates upstream data quality issue).
- **NULL product_id rate:** Alert if >5% of rows have NULL product attributes (indicates product master lag).
- **Negative margin:** Alert if >1% of rows have negative margin_pct (indicates pricing or cost data issue).
- **Load time SLA:** Alert if table creation takes >30 minutes (indicates performance degradation).

### Refresh Strategy
- **Current:** Full table refresh (DROP + CREATE). Acceptable for <500M rows.
- **Recommended for scale:** Implement incremental load (INSERT only new order_items since last run) to reduce compute and I/O.

### Documentation Debt
- Add `-- Owner: [team]` and `-- Schedule: [frequency]` comments to code.
- Document business rules for margin_pct zero-check and discount_pct null handling.
- Add data lineage diagram showing this component's position in the data pipeline.