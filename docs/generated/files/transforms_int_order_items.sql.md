# transforms/int_order_items.sql

## Component Overview
- **Layer:** Transforms
- **Type:** Table (materialized)
- **Schedule:** Not specified in code; infer from orchestration layer
- **Owner:** Not specified in code; recommend adding to header comments

---

## Purpose

This component enriches raw order line items with product master data and order context to create a single source of truth for item-level financial metrics. It computes revenue, cost of goods sold (COGS), and margin calculations at the order-item grain, enabling downstream analytics on product profitability, discount impact, and channel performance. The output is consumed by reporting dashboards, BI tools, and financial analysis workflows that require item-level visibility into order economics.

---

## Inputs

| Source | Purpose | Criticality |
|--------|---------|-------------|
| **spectrum.raw_order_items** | Raw order line item records including quantity, unit price, discount, and line totals. This component needs it to obtain the transactional facts (what was sold, how much, at what price). | Critical |
| **staging.stg_raw_orders** | Staging layer containing cleaned order headers with customer ID, order date, status, channel, country, and payment method. This component needs it to add order context (when, where, how the order was placed) to each line item. | Critical |
| **staging.stg_raw_products** | Staging layer containing product master data including SKU, name, category, brand, and unit cost. This component needs it to classify items and calculate COGS and margin (unit cost is essential for profitability math). | Critical |

---

## Outputs

| Target | Contents | Downstream Consumers |
|--------|----------|---------------------|
| **transforms.int_order_items** | Denormalized order item records with order context, product attributes, and computed financial metrics at the order-item grain. One row per order line item. | Fact tables in marts layer (e.g., `marts.fct_orders`), BI tools (Tableau, Looker), financial reporting, product analytics, customer segmentation models, discount analysis reports. |

---

## Key Business Logic

### 1. **Data Validation & Filtering**
- **Order Item Validation:** Filters to `order_id IS NOT NULL` and `quantity > 0` to exclude orphaned or voided line items.
- **Why:** Prevents invalid or incomplete transactions from inflating revenue or margin metrics. Ensures every row represents a genuine sale.

### 2. **Type Casting & Precision**
- Casts all numeric fields to appropriate types: `BIGINT` for IDs, `INT` for quantity, `DECIMAL(10,2)` for prices, `DECIMAL(5,2)` for percentages.
- **Why:** Ensures consistent precision for financial calculations and prevents floating-point rounding errors in downstream aggregations. Decimal types are required for accounting accuracy.

### 3. **Revenue Calculations**
- **Gross Revenue:** Line total as-is from raw data (`line_total`).
- **Net Revenue:** Line total adjusted for discount percentage: `line_total * (1 - discount_pct / 100)`.
- **Why:** Gross revenue represents the list price value; net revenue represents actual cash collected. Both are needed for discount impact analysis and revenue recognition.

### 4. **Cost of Goods Sold (COGS) & Margin**
- **COGS:** `quantity * unit_cost` (from product master).
- **Gross Margin (dollars):** `line_total - COGS`.
- **Margin %:** `(gross_margin / line_total) * 100`, with division-by-zero protection (returns 0 if line_total ≤ 0).
- **Why:** COGS is the direct cost to fulfill the order; margin shows profitability per item. Margin % enables comparison across products with different price points. Division-by-zero protection prevents errors on edge cases (free items, returns).

### 5. **Null Handling**
- Uses `NVL(unit_cost, 0)` when joining to products, defaulting missing costs to zero.
- **Why:** Products may not have cost data in staging; defaulting to zero prevents null propagation but flags items that need cost investigation. Consider adding a data quality flag for missing costs.

### 6. **Discount & Product Status Flags**
- **is_discounted:** Boolean flag set to TRUE if `discount_pct > 0`.
- **is_discontinued_product:** Boolean flag set to TRUE if product status is 'Discontinued'.
- **Why:** Enables quick filtering and segmentation in downstream queries. Allows analysis of discount effectiveness and discontinued product revenue tail-off.

### 7. **Join Strategy**
- **INNER JOIN** to `stg_raw_orders`: Ensures every line item has a valid order context. Filters out orphaned items.
- **LEFT JOIN** to `stg_raw_products`: Allows line items to exist even if product master data is missing (e.g., deleted products). Margin calculations degrade gracefully with `NVL`.
- **Why:** Order context is mandatory; product context is optional to handle data lag or deletions without losing transaction records.

---

## Column Descriptions

| Column | Type | Description | Example |
|--------|------|-------------|---------|
| **order_item_id** | BIGINT | Unique identifier for the order line item. Primary key. | 987654321 |
| **order_id** | BIGINT | Foreign key to the order. Used for grouping items within an order. | 123456789 |
| **product_id** | BIGINT | Foreign key to the product master. Used for product-level aggregations. | 555 |
| **customer_id** | BIGINT | Foreign key to the customer. Enables customer-level analysis. | 42 |
| **order_date** | DATE | Date the order was placed. Used for time-series analysis and period bucketing. | 2024-01-15 |
| **order_status** | VARCHAR | Status of the order (e.g., 'Completed', 'Cancelled', 'Pending'). Filters for valid revenue. | Completed |
| **order_channel** | VARCHAR | Channel through which the order was placed (e.g., 'Web', 'Mobile', 'In-Store'). Enables channel performance analysis. | Web |
| **sku** | VARCHAR | Stock keeping unit; unique product identifier. Used for inventory and fulfillment. | SKU-12345 |
| **product_name** | VARCHAR | Human-readable product name. Used in reports and dashboards. | Wireless Headphones Pro |
| **category** | VARCHAR | Product category for segmentation. | Electronics |
| **brand** | VARCHAR | Product brand. Enables brand-level profitability analysis. | TechBrand |
| **quantity** | INT | Number of units sold in this line item. | 2 |
| **sold_unit_price** | DECIMAL(10,2) | Price per unit at which the item was sold (before discount). | 99.99 |
| **discount_pct** | DECIMAL(5,2) | Discount percentage applied to this line item. | 10.00 |
| **gross_revenue** | DECIMAL(12,2) | Total line value before discount (quantity × sold_unit_price). | 199.98 |
| **net_revenue** | DECIMAL(12,2) | Total line value after discount. Used for revenue recognition and KPI reporting. | 179.98 |
| **cogs** | DECIMAL(12,2) | Cost of goods sold (quantity × unit_cost from product master). | 80.00 |
| **gross_margin** | DECIMAL(12,2) | Profit per line item in dollars (net_revenue - cogs). | 99.98 |
| **margin_pct** | DECIMAL(5,2) | Profit margin as a percentage of gross revenue. Used for product profitability ranking. | 50.00 |
| **is_discounted** | BOOLEAN | Flag indicating whether a discount was applied to this item. | true |
| **is_discontinued_product** | BOOLEAN | Flag indicating whether the product is discontinued. Helps identify revenue from legacy products. | false |
| **_loaded_at** | TIMESTAMP | Timestamp when this record was loaded into the transforms layer. Used for SLA monitoring and data freshness checks. | 2024-01-16 14:32:00 |

---

## Data Quality & Edge Cases

### Null Handling
- **unit_cost:** Defaults to 0 via `NVL(unit_cost, 0)` when product master data is missing. **Risk:** Margin calculations will be artificially high for products without cost data. **Mitigation:** Add a data quality check to flag items with null unit_cost; consider a separate flag column `has_cost_data`.
- **discount_pct:** Defaults to 0 via `NVL(discount_pct, 0)` in revenue calculations. **Risk:** If discount_pct is null in raw data, it's treated as no discount. **Mitigation:** Validate that discount_pct is never null in raw layer; add a NOT NULL constraint if possible.
- **product_status:** LEFT JOIN allows null values if product is not found in staging. **Risk:** is_discontinued_product flag will be FALSE for orphaned products. **Mitigation:** Add a separate flag `product_not_found` to distinguish missing products from active ones.

### Deduplication Strategy
- **No explicit deduplication:** Assumes `spectrum.raw_order_items` contains no duplicate rows. **Risk:** If raw layer has duplicates, they will propagate to transforms. **Mitigation:** Add a ROW_NUMBER() window function to deduplicate by order_item_id, keeping the most recent record.
- **Join cardinality:** INNER JOIN to orders and LEFT JOIN to products assume one-to-one relationships. **Risk:** If a product_id maps to multiple rows in stg_raw_products (e.g., due to SCD Type 2 versioning), line items will fan out. **Mitigation:** Verify that stg_raw_products is deduplicated by product_id; if using SCD, join on product_id AND effective_date.

### Assumptions About Upstream Data
1. **Order IDs are unique in stg_raw_orders:** If orders are duplicated, line items will fan out.
2. **Product IDs are unique in stg_raw_products:** If products are versioned (SCD), join will produce multiple rows per item.
3. **unit_cost is always non-negative:** Negative costs would produce negative COGS and inflated margins.
4. **discount_pct is between 0 and 100:** Values outside this range will produce nonsensical net revenue.
5. **line_total is pre-calculated correctly in raw layer:** This component does not recalculate line_total; it trusts the source.
6. **order_date is always populated:** Used as a SORTKEY; null values could cause performance issues.

### What Could Break
- **Product master lag:** If a product is deleted from stg_raw_products after an order is placed, the LEFT JOIN will return nulls for product attributes. Margin calculations will degrade (unit_cost defaults to 0).
- **Discount percentage format change:** If raw layer changes from percentage (0–100) to decimal (0–1), net revenue calculations will be wrong.
- **Currency changes:** If orders span multiple currencies but are not converted, revenue and margin aggregations will be meaningless.
- **Order status values change:** If order_status values are renamed (e.g., 'Completed' → 'Complete'), downstream filters will break.
- **Duplicate orders in raw layer:** If raw_order_items contains duplicate rows, they will propagate, inflating revenue.

---

## Performance Notes

### Distribution & Sort Keys
- **DISTKEY(order_id):** Distributes rows across nodes by order_id. **Rationale:** Most downstream queries will filter or group by order_id (e.g., "revenue by order"). Co-locating line items from the same order on the same node reduces network traffic during joins and aggregations.
- **SORTKEY(order_date, order_id):** Sorts rows by order_date (primary) then order_id (secondary). **Rationale:** Time-series queries (e.g., "revenue by month") will benefit from order_date clustering. Secondary sort on order_id improves locality for order-level aggregations.
- **Implication:** Queries filtering on order_date will use zone maps for efficient pruning. Queries filtering only on order_id will require a full scan unless they also filter on order_date.

### Join Strategy
- **INNER JOIN to stg_raw_orders:** Filters out orphaned line items early. Assumes stg_raw_orders is smaller or similarly sized to raw_order_items. **Risk:** If stg_raw_orders is much larger, the join could be expensive. **Mitigation:** Verify that stg_raw_orders is indexed on order_id.
- **LEFT JOIN to stg_raw_products:** Preserves all line items even if product data is missing. **Risk:** If stg_raw_products is very large and not indexed, the join could be slow. **Mitigation:** Ensure stg_raw_products is indexed on product_id and has a reasonable row count.

### Expensive Operations
- **ROUND() on every row:** Applied to net_revenue, cogs, gross_margin, and margin_pct. **Cost:** Minimal; ROUND is a scalar function. **Mitigation:** None needed unless profiling shows this is a bottleneck.
- **CASE statement for margin_pct:** Division-by-zero check on every row. **Cost:** Minimal; CASE is fast. **Mitigation:** None needed.
- **GETDATE() on every row:** Generates current timestamp for _loaded_at. **Cost:** Minimal; executed once per query, not per row. **Mitigation:** None needed.

### Full Table Scans
- **spectrum.raw_order_items:** Scanned entirely (no WHERE clause filters on indexed columns). **Cost:** Depends on table size. **Mitigation:** If raw_order_items is very large, consider partitioning by order_date in the raw layer and filtering here.
- **stg_raw_orders & stg_raw_products:** Scanned entirely before joining. **Cost:** Depends on table size. **Mitigation:** Ensure these staging tables are reasonably sized; if they grow unbounded, consider incremental loads.

### Materialization Strategy
- **CREATE TABLE AS SELECT (CTAS):** Materializes the entire result set. **Rationale:** Enables fast downstream queries without re-computing joins and calculations. **Trade-off:** Requires storage and refresh overhead. **Alternative:** Use a view if this data is rarely queried or if freshness is critical.
- **DROP TABLE IF EXISTS:** Ensures a clean slate on each refresh. **Risk:** If the refresh fails mid-way, the table is dropped but not recreated, breaking downstream dependencies. **Mitigation:** Use a staging table and atomic rename, or add error handling.

### Refresh Considerations
- **ANALYZE:** Runs after table creation to update table statistics. **Benefit:** Helps the query planner make better decisions on downstream queries. **Cost:** Scans the entire table. **Mitigation:** Consider running ANALYZE asynchronously if the table is very large.
- **GRANT SELECT:** Grants read access to analytics_readers group. **Benefit:** Enables BI tools and analysts to query the table. **Implication:** No write access; table is read-only for consumers.

---

## Dependencies

### Upstream (Must Run Before This Component)
1. **spectrum.raw_order_items** — Raw data ingestion pipeline. Must populate raw_order_items with order line items.
2. **staging.stg_raw_orders** — Data staging pipeline. Must clean and deduplicate raw orders, populate order_id, customer_id, order_date, order_status, order_channel, billing_country, payment_method.
3. **staging.stg_raw_products** — Data staging pipeline. Must clean and deduplicate raw products, populate product_id, sku, product_name, category, subcategory, brand, unit_cost, product_status.

**SLA Requirement:** All three upstream sources must be refreshed before this component runs. Recommend a dependency DAG in orchestration tool (e.g., Airflow, dbt) to enforce order.

### Downstream (Depends on This Component's Output)
1. **marts.fct_orders** — Fact table that aggregates int_order_items to order grain. Depends on int_order_items for item-level metrics.
2. **marts.fct_products** — Fact table that aggregates int_order_items to product grain. Depends on int_order_items for product-level profitability.
3. **BI Dashboards** — Tableau, Looker, or other BI tools that query int_order_items directly for order item details, discount analysis, margin trends.
4. **Financial Reporting** — Revenue recognition, COGS reconciliation, margin analysis reports.
5. **Customer Analytics** — Customer segmentation, RFM analysis, lifetime value calculations (depends on order-level aggregations of int_order_items).
6. **Product Analytics** — Product performance, category trends, brand profitability (depends on product-level aggregations of int_order_items).

**SLA Requirement:** Downstream components should not run until int_order_items is fully refreshed and ANALYZE is complete. Recommend a 30-minute SLA for this component's refresh.

### External Dependencies
- **None detected** in the code. No API calls, external configs, or system references.
- **Implicit:** Assumes Redshift cluster is available and has sufficient storage for the materialized table.

---

## Recommendations for Improvement

1. **Add data quality checks:** Validate that discount_pct is between 0–100, unit_cost is non-negative, and line_total matches quantity × sold_unit_price.
2. **Handle product master lag:** Add a `product_found` flag to distinguish missing products from active ones. Consider a separate `unit_cost_source` column to track whether cost came from product master or was defaulted.
3. **Deduplication:** Add a ROW_NUMBER() window to deduplicate raw_order_items by order_item_id in case of upstream duplicates.
4. **Incremental refresh:** If raw_order_items is very large, consider an incremental load strategy (e.g., only refresh orders from the last 7 days) instead of full CTAS.
5. **Documentation in code:** Add comments explaining the business rules for margin calculation, discount logic, and product status filtering.
6. **Owner & schedule:** Add comments specifying the component owner and refresh schedule (e.g., "Owned by Finance Analytics; refreshes daily at 2 AM UTC").