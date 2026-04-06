# transforms/int_order_items.sql

## Component Overview
- **Layer:** Transforms
- **Type:** Table (materialized)
- **Schedule:** Not specified in code; infer from orchestration layer
- **Owner:** Not specified in code; recommend adding to header comments

---

## Purpose

This component enriches raw order line items with product master data and order context to create a single source of truth for item-level financial analysis. It computes critical revenue, cost, and margin metrics at the order-item grain, enabling downstream reporting on profitability, discount impact, and product performance. Analytics teams, finance, and product management consume this table for dashboards, margin analysis, and customer profitability models.

---

## Inputs

| Source | Purpose | Criticality |
|--------|---------|-------------|
| **spectrum.raw_order_items** | Raw order line item records including quantity, unit price, discount, and line totals. This component needs it to establish the transactional grain and base financial values. | Critical |
| **staging.stg_raw_orders** | Staging layer containing cleaned order headers (customer_id, order_date, status, channel, country, payment method). Joined to provide order context and customer linkage for each item. | Critical |
| **staging.stg_raw_products** | Staging layer containing product master data (SKU, name, category, brand, unit cost, status). Joined to attach product attributes and cost data needed for margin calculations. | Critical |

---

## Outputs

| Target | Contents | Downstream Consumers |
|--------|----------|---------------------|
| **transforms.int_order_items** | Denormalized order-item-level fact table with 20+ columns including order metadata, product attributes, quantities, prices, and computed revenue/margin metrics. Grain: one row per order line item. | Mart tables (fct_order_items, dim_products), BI dashboards (margin analysis, product performance, customer profitability), financial reporting, discount impact analysis |

---

## Key Business Logic

### 1. **Data Validation & Filtering**
```
WHERE oi.order_id IS NOT NULL AND oi.quantity > 0
```
- **Why:** Removes orphaned line items (no parent order) and zero/negative quantities (data errors or returns not yet modeled separately).
- **Impact:** Ensures only valid, billable transactions flow downstream.

### 2. **Type Casting & Precision**
- Order/product IDs cast to BIGINT for consistent join keys and downstream compatibility.
- Prices cast to DECIMAL(10,2) and DECIMAL(12,2) to preserve financial precision and avoid floating-point rounding errors in margin calculations.
- **Why:** Financial data requires exact arithmetic; implicit type coercion can cause reconciliation failures.

### 3. **Revenue Metrics Hierarchy**

| Metric | Formula | Business Meaning |
|--------|---------|------------------|
| **gross_revenue** | `line_total` | Total revenue before any discounts; the invoice amount. |
| **net_revenue** | `line_total × (1 - discount_pct/100)` | Revenue after discount; what the company actually receives. |
| **cogs** | `quantity × unit_cost` | Cost of goods sold; inventory valuation at standard cost. |
| **gross_margin** | `line_total - cogs` | Absolute profit per item before operating expenses. |
| **margin_pct** | `(gross_margin / line_total) × 100` | Margin as a percentage; normalized for comparison across price points. |

- **Why this hierarchy:** Enables drill-down analysis from top-line revenue to profitability; supports pricing strategy review and product mix optimization.
- **Edge case:** `margin_pct` defaults to 0 if `line_total ≤ 0` to avoid division by zero; flagged for investigation.

### 4. **Discount & Product Status Flags**
```sql
is_discounted = (discount_pct > 0)
is_discontinued_product = (product_status = 'Discontinued')
```
- **Why:** Boolean flags enable fast filtering in downstream queries (e.g., "show margin impact of discounted items" or "identify sales of discontinued SKUs").
- **Assumption:** `product_status` is maintained in the product staging table; if missing, all items default to FALSE.

### 5. **Join Strategy**
- **INNER JOIN to stg_raw_orders:** Enforces referential integrity; drops order items with no matching order header (data corruption).
- **LEFT JOIN to stg_raw_products:** Allows items with missing product master data (e.g., deleted SKUs); `unit_cost` defaults to NULL, coalesced to 0 in margin calculations.
- **Why:** Orders are mandatory; products may be soft-deleted but items remain billable.

### 6. **Null Handling**
- `NVL(discount_pct, 0)` — treats missing discounts as zero (no discount applied).
- `NVL(p.unit_cost, 0)` — treats missing costs as zero (conservative margin estimate; flags for investigation).
- **Risk:** If product costs are systematically missing, margin metrics will be overstated.

---

## Column Descriptions

| Column | Type | Description | Example |
|--------|------|-------------|---------|
| **order_item_id** | BIGINT | Unique identifier for this line item; primary key. | 987654321 |
| **order_id** | BIGINT | Foreign key to order header; enables aggregation to order level. | 123456 |
| **product_id** | BIGINT | Foreign key to product master; enables product-level analysis. | 5001 |
| **customer_id** | BIGINT | Foreign key to customer; enables customer profitability analysis. | 42 |
| **order_date** | DATE | Date the order was placed; used for time-series analysis and fiscal period assignment. | 2024-01-15 |
| **order_status** | VARCHAR | Order fulfillment status (e.g., 'Completed', 'Pending', 'Cancelled'); filters for revenue recognition. | Completed |
| **order_channel** | VARCHAR | Sales channel (e.g., 'Web', 'Mobile', 'In-Store'); enables channel profitability analysis. | Web |
| **sku** | VARCHAR | Stock-keeping unit; human-readable product identifier for reconciliation. | SKU-12345-BLK |
| **product_name** | VARCHAR | Product display name; used in reports and dashboards. | Wireless Headphones Pro |
| **category** | VARCHAR | Product category for hierarchical analysis and segmentation. | Electronics |
| **quantity** | INT | Units sold in this line item. | 2 |
| **sold_unit_price** | DECIMAL(10,2) | Price per unit charged to customer (before discount). | 149.99 |
| **net_revenue** | DECIMAL(12,2) | Revenue after discount; the amount the company receives. | 269.98 |
| **gross_margin** | DECIMAL(12,2) | Absolute profit (net_revenue - cogs); used in margin analysis. | 89.99 |
| **margin_pct** | DECIMAL(5,2) | Margin as a percentage of net revenue; normalized KPI. | 33.33 |
| **is_discounted** | BOOLEAN | Flag indicating whether a discount was applied; enables fast filtering. | true |
| **_loaded_at** | TIMESTAMP | Timestamp when this row was inserted; used for SLA monitoring and incremental load logic. | 2024-01-16 10:30:45 |

---

## Data Quality & Edge Cases

### Null Handling
| Scenario | Current Behavior | Risk | Mitigation |
|----------|------------------|------|-----------|
| Missing `discount_pct` | Treated as 0 (no discount) | Overstates net_revenue if discounts are not recorded upstream | Validate discount_pct is NOT NULL in staging layer |
| Missing `unit_cost` | Treated as 0 in margin calculations | Overstates gross_margin and margin_pct; product profitability appears inflated | Flag rows with NULL unit_cost; implement cost estimation logic or manual review |
| Missing `product_status` | Defaults to FALSE for is_discontinued_product | Discontinued products not flagged; may inflate active product metrics | Ensure product staging layer populates status for all products |
| Missing `order_id` or `quantity ≤ 0` | Filtered out in CTE | Valid items may be lost if upstream data quality degrades | Monitor row counts pre/post filter; alert if drop exceeds threshold |

### Deduplication Strategy
- **No explicit deduplication:** Assumes `spectrum.raw_order_items` contains one row per order line item (no duplicates).
- **Risk:** If raw layer contains duplicate line items (e.g., from ETL reruns), this table will also contain duplicates.
- **Mitigation:** Add `ROW_NUMBER()` deduplication in staging layer; validate uniqueness of (order_id, product_id, line_number) in raw layer.

### Key Assumptions
1. **Order IDs are stable:** An order_id never changes; used as immutable join key.
2. **Product costs are historical:** `unit_cost` in the product staging table reflects the cost at the time of sale (not current cost). If product costs are updated retroactively, historical margins will be recalculated.
3. **Discount percentages are accurate:** Discounts are recorded as percentages; no logic to detect or reconcile discount vs. actual price variance.
4. **Order status is final:** `order_status` is used as-is; no logic to handle status transitions (e.g., cancelled orders).
5. **No returns or adjustments:** This table assumes all items are billable; returns/credits are modeled separately.

### What Could Break
- **Upstream schema changes:** If `spectrum.raw_order_items` renames or removes `discount_pct`, the query fails.
- **Product master gaps:** If `staging.stg_raw_products` is not refreshed, new products have no cost data; margins are understated.
- **Referential integrity violations:** If `staging.stg_raw_orders` is incomplete (missing order headers), INNER JOIN silently drops items.
- **Negative line totals:** If `line_total` is negative (e.g., credits), `margin_pct` calculation may produce unexpected results (e.g., negative margin on a credit).
- **Discount > 100%:** If `discount_pct > 100`, `net_revenue` becomes negative; no validation prevents this.

---

## Performance Notes

### Join Strategy & Implications
| Join | Type | Implication |
|------|------|-------------|
| `order_items` → `stg_raw_orders` | INNER | Enforces referential integrity but may drop orphaned items. Redshift uses hash join if both tables fit in memory; broadcast join if one is small. |
| `order_items` → `stg_raw_products` | LEFT | Preserves items with missing products; uses hash join with NULL handling. Slightly more expensive than INNER join due to NULL checks. |

### Distribution & Sort Keys
```sql
DISTKEY(order_id)
SORTKEY(order_date, order_id)
```
- **DISTKEY(order_id):** Distributes rows across nodes by order_id. Ensures all items for a single order co-locate on the same node, enabling efficient aggregation to order level (e.g., SUM(net_revenue) GROUP BY order_id).
- **SORTKEY(order_date, order_id):** Sorts within each node by date, then order_id. Enables efficient range scans on date (e.g., "last 30 days") and sequential scans for time-series analysis.
- **Trade-off:** Optimizes for order-level and time-series queries; product-level aggregations (GROUP BY product_id) may require redistribution.

### Expensive Operations
- **Computed columns (margin_pct, gross_margin):** Calculated for every row; no pre-aggregation. If downstream queries aggregate these, consider materializing aggregates in a separate mart table.
- **ROUND() functions:** Applied to 4 numeric columns; minimal overhead but adds CPU cost at scale.
- **CAST operations:** Type conversions on every row; negligible overhead in Redshift but worth noting for very large tables (>1B rows).

### Full Table Scans
- No WHERE clause in the final SELECT; the entire enriched CTE is materialized.
- **Impact:** Every query on this table scans all rows unless filtered by DISTKEY or SORTKEY. Recommend adding partition pruning in downstream queries (e.g., WHERE order_date >= CURRENT_DATE - 90).

### Table Size Estimate
- Assuming 100M order items, ~20 columns, ~200 bytes per row → ~20 GB uncompressed.
- Redshift compression typically achieves 3-5x reduction → ~4-7 GB on disk.
- Recommend monitoring table size and archiving old data (>2 years) to a data lake.

---

## Dependencies

### Upstream (Must Run Before This Component)
1. **spectrum.raw_order_items** — Raw data ingestion from source system (e.g., ERP, order management system). Must complete before this transform runs.
2. **staging.stg_raw_orders** — Staging layer that cleans and validates order headers. Must run after raw ingestion and before this transform.
3. **staging.stg_raw_products** — Staging layer that cleans and validates product master data. Must run after raw ingestion and before this transform.

### Downstream (Components That Depend on This Output)
1. **mart.fct_order_items** — Fact table for BI tools; aggregates and denormalizes this table for reporting.
2. **mart.dim_products** — Product dimension; may join to this table for product-level metrics.
3. **reports.margin_analysis** — Dashboard showing margin by product, category, and channel.
4. **reports.customer_profitability** — Dashboard showing customer-level revenue and margin.
5. **financial_reconciliation.revenue_by_channel** — Finance reconciliation report; validates net_revenue against GL.
6. **discount_impact_analysis** — Ad-hoc analysis of discount elasticity and margin impact.

### External Dependencies
- **Redshift cluster:** Requires sufficient disk space and compute capacity; monitor cluster health.
- **IAM permissions:** User running this script must have CREATE TABLE, DROP TABLE, and GRANT permissions on the transforms schema.
- **Spectrum external schema:** Must be configured to read from S3 (or other object storage) where raw_order_items is stored.

### Orchestration Assumptions
- This script is executed as part of a DAG (directed acyclic graph) after upstream dependencies complete.
- Recommend scheduling after 02:00 UTC (assuming US business hours) to minimize impact on operational queries.
- Add retry logic for transient failures (e.g., Redshift cluster unavailable).

---

## Maintenance & Monitoring

### Recommended Alerts
- **Row count drop >10%:** Indicates upstream data quality issue or filtering logic change.
- **NULL unit_cost >5%:** Indicates product master data gaps; investigate missing costs.
- **Negative margin_pct >1%:** Indicates pricing or cost data anomalies; review manually.
- **Query runtime >30 minutes:** Indicates cluster performance degradation or data volume spike.

### Recommended Enhancements
1. Add `_dbt_source_relation` column to track data lineage (if using dbt).
2. Implement incremental load logic (INSERT only new/modified items) instead of full table rebuild.
3. Add data quality tests (e.g., margin_pct between -100 and 100, net_revenue >= 0).
4. Document assumptions about product cost timing (e.g., "unit_cost reflects cost at time of sale").
5. Add owner and SLA metadata to table comments.