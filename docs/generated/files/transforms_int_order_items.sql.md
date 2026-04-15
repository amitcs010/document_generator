# transforms/int_order_items.sql

## Component Overview
- **Layer:** Transforms
- **Type:** Table (materialized)
- **Schedule:** Not specified in code; infer from orchestration layer
- **Owner:** Not specified in code; recommend adding to header comments

---

## Purpose

This component enriches raw order line items with product master data and order context, then computes item-level financial metrics (revenue, cost of goods sold, margin). It serves as the foundational fact table for order analytics, enabling downstream reporting on product profitability, discount impact, and channel performance. Consumed by BI tools, finance dashboards, and customer analytics workflows.

---

## Inputs

| Source | Purpose | Criticality |
|--------|---------|-------------|
| **spectrum.raw_order_items** | Raw order line item records containing quantity, unit price, discount, and line totals. This component needs it to access transactional detail. | Critical |
| **staging.stg_raw_orders** | Staging layer order headers with customer ID, order date, status, channel, country, and payment method. Provides order-level context and customer linkage. | Critical |
| **staging.stg_raw_products** | Staging layer product master with SKU, name, category, brand, and unit cost. Enables margin calculation and product classification. | Critical (LEFT JOIN allows nulls, but unit_cost nulls degrade margin accuracy) |

---

## Outputs

| Target | Contents | Downstream Consumers |
|--------|----------|---------------------|
| **transforms.int_order_items** | Denormalized fact table with ~25 columns: order item detail, product attributes, order context, and computed financial metrics. One row per order line item. | Revenue reporting dashboards, margin analysis, product performance analytics, customer lifetime value models, discount effectiveness studies |

---

## Key Business Logic

### 1. **Data Validation & Filtering**
- **Order ID NOT NULL:** Excludes orphaned line items with no order reference.
- **Quantity > 0:** Filters out cancellations, returns, or data errors with zero/negative quantities. Assumption: negative quantities are handled separately (e.g., in a returns table).
- **INNER JOIN to orders:** Enforces referential integrity; drops line items for orders not in staging layer (e.g., orders still in ETL pipeline).

### 2. **Revenue Metrics Calculation**
- **Gross Revenue:** Line total as-is from raw data (before discount application).
- **Net Revenue:** `line_total × (1 - discount_pct / 100)` — represents actual cash recognized after discount. Used for top-line revenue reporting.
- **COGS (Cost of Goods Sold):** `quantity × unit_cost` — assumes unit_cost is constant per product (no variance by order date or supplier). Null unit_cost defaults to 0, which *understates* COGS and *overstates* margin.
- **Gross Margin:** `net_revenue - COGS` — absolute profit per line item.
- **Margin %:** `(gross_margin / line_total) × 100` — normalized profitability; handles division-by-zero with CASE statement.

### 3. **Discount & Product Status Flags**
- **is_discounted:** Boolean flag for any discount > 0%. Enables filtering/segmentation in downstream queries.
- **is_discontinued_product:** Flags line items sold after product discontinuation. Useful for identifying data quality issues or late-arriving orders for discontinued SKUs.

### 4. **Deduplication Strategy**
- No explicit deduplication; assumes `spectrum.raw_order_items` is already deduplicated at the source layer.
- **Risk:** If raw layer contains duplicate line items (e.g., from failed ETL retries), this table will inherit them. Recommend adding a ROW_NUMBER() deduplication step if upstream duplicates are suspected.

### 5. **Join Strategy**
- **INNER JOIN to orders:** Strict referential integrity; only includes line items for orders in staging layer.
- **LEFT JOIN to products:** Allows line items for products not yet in master (e.g., new products, data lag). Null product attributes are preserved; unit_cost defaults to 0 in calculations.

---

## Column Descriptions

| Column | Type | Description | Example |
|--------|------|-------------|---------|
| **order_item_id** | BIGINT | Unique identifier for the order line item. Primary key. | 987654321 |
| **order_id** | BIGINT | Foreign key to order header. Distribution key for Redshift. | 123456 |
| **product_id** | BIGINT | Foreign key to product master. | 5001 |
| **customer_id** | BIGINT | Foreign key to customer. Inherited from order header. | 42 |
| **order_date** | DATE | Date order was placed. Sort key for time-series queries. | 2024-01-15 |
| **order_status** | VARCHAR | Order fulfillment status (e.g., 'Completed', 'Pending', 'Cancelled'). | Completed |
| **order_channel** | VARCHAR | Sales channel (e.g., 'Web', 'Mobile', 'In-Store', 'Wholesale'). | Web |
| **sku** | VARCHAR | Product stock-keeping unit. | SKU-12345 |
| **product_name** | VARCHAR | Human-readable product name. | Wireless Headphones Pro |
| **category** | VARCHAR | Product category for segmentation. | Electronics |
| **quantity** | INT | Number of units sold in this line item. Filtered to > 0. | 2 |
| **sold_unit_price** | DECIMAL(10,2) | Price per unit at time of sale. | 149.99 |
| **discount_pct** | DECIMAL(5,2) | Discount percentage applied (0–100). | 10.00 |
| **net_revenue** | DECIMAL(12,2) | Revenue after discount: `line_total × (1 - discount_pct / 100)`. Used for top-line reporting. | 269.98 |
| **gross_margin** | DECIMAL(12,2) | Profit per line item: `net_revenue - COGS`. | 134.99 |
| **margin_pct** | DECIMAL(5,2) | Margin as percentage of gross revenue. Null-safe; returns 0 if line_total ≤ 0. | 49.81 |
| **is_discounted** | BOOLEAN | TRUE if discount_pct > 0. Enables discount cohort analysis. | TRUE |
| **_loaded_at** | TIMESTAMP | ETL load timestamp (GETDATE() at execution). Used for SCD tracking and freshness monitoring. | 2024-01-20 14:32:15 |

---

## Data Quality & Edge Cases

### Null Handling
| Field | Null Behavior | Impact | Mitigation |
|-------|---------------|--------|-----------|
| **unit_cost** (from products) | LEFT JOIN allows nulls; defaults to 0 in COGS calculation | Understates COGS, overstates margin_pct | Recommend NOT NULL constraint in stg_raw_products or explicit imputation (e.g., category average) |
| **discount_pct** | NVL() defaults to 0 if null | Treats missing discount as 0% (conservative). | Acceptable; aligns with business logic. |
| **product_status** | LEFT JOIN allows nulls; CASE statement treats null as FALSE | Products not in master are not flagged as discontinued. | Acceptable; only flags known discontinuations. |
| **order_id in raw_order_items** | WHERE clause filters out nulls | Orphaned line items excluded. | Correct; prevents referential integrity violations. |

### Deduplication Strategy
- **Current approach:** None. Assumes upstream deduplication.
- **Risk:** If `spectrum.raw_order_items` contains duplicates (e.g., from failed Spectrum query retries), they propagate downstream.
- **Recommendation:** Add deduplication CTE:
  ```sql
  WITH deduplicated AS (
    SELECT * FROM spectrum.raw_order_items
    WHERE ROW_NUMBER() OVER (PARTITION BY order_item_id ORDER BY _loaded_at DESC) = 1
  )
  ```

### Assumptions About Upstream Data
1. **order_item_id is unique** in raw layer (no duplicates).
2. **unit_cost is static** per product (no time-varying costs; no supplier variance).
3. **discount_pct is pre-validated** (0–100 range; no negative discounts).
4. **line_total is pre-calculated** in raw layer and matches `quantity × sold_unit_price × (1 - discount_pct / 100)`.
5. **order_date is populated** for all orders in staging layer.

### What Could Break
| Scenario | Symptom | Mitigation |
|----------|---------|-----------|
| **Duplicate line items in raw layer** | Revenue metrics double-counted; margin_pct distorted. | Add ROW_NUMBER() deduplication. |
| **Missing unit_cost in products** | Margin_pct inflated (COGS = 0). | Add NOT NULL constraint; impute with category average. |
| **Stale product master** | New products have null attributes; old products not flagged as discontinued. | Implement SCD Type 2 in stg_raw_products; add effective_date range. |
| **Order status changes post-load** | Historical line items show current status, not status at time of sale. | Add order_status_at_item_date or use immutable staging snapshot. |
| **Negative quantities in raw layer** | WHERE quantity > 0 filters them out silently; no audit trail. | Log filtered records to a quarantine table for investigation. |
| **Discount > 100%** | Net revenue becomes negative (data error). | Add validation: `WHERE discount_pct <= 100`. |

---

## Performance Notes

### Join Strategy & Implications
| Join | Type | Cardinality | Performance Impact |
|------|------|-------------|-------------------|
| **order_items → orders** | INNER | N:1 (many line items per order) | Efficient; reduces row count. Redshift broadcasts smaller orders table. |
| **order_items → products** | LEFT | N:1 (many line items per product) | Efficient; LEFT JOIN preserves all line items even if product missing. Redshift broadcasts products table. |

### Distribution & Sort Keys
- **DISTKEY(order_id):** Distributes rows across nodes by order_id. Optimizes joins on order_id and enables efficient aggregations by order (e.g., order total revenue). Assumption: order_id cardinality is high enough to avoid skew.
- **SORTKEY(order_date, order_id):** Enables efficient range scans on order_date (common in time-series queries). Secondary sort on order_id improves locality for order-level aggregations.
- **Implication:** Queries filtering on order_date will be fast; queries filtering on product_id or customer_id will require full table scans.

### Expensive Operations
- **ROUND() on every row:** Minimal cost; applied to 6 numeric columns. Negligible impact.
- **CASE statements:** Minimal cost; used for margin_pct division-by-zero and flag logic.
- **No subqueries or window functions:** Query is straightforward; no expensive operations detected.

### Materialization Strategy
- **Table vs. View:** Materialized as table (not view). Enables DISTKEY/SORTKEY optimization and fast downstream queries. Trade-off: requires full refresh on each run (no incremental updates).
- **Recommendation:** Consider incremental load strategy (e.g., only refresh orders from last 7 days) if table grows beyond 1B rows.

### Estimated Row Count & Storage
- **Rows:** ~1 row per order line item. If average order has 3 items and system processes 1M orders/month, expect ~3M rows/month.
- **Storage:** ~25 columns × 3M rows × ~100 bytes/row ≈ 7.5 GB/month (rough estimate). Monitor with `SELECT COUNT(*) FROM transforms.int_order_items;`

---

## Dependencies

### Upstream (Must Run Before This Component)
1. **spectrum.raw_order_items** — Raw data ingestion from source system (e.g., Spectrum external table from S3).
2. **staging.stg_raw_orders** — ETL pipeline that cleanses and stages order headers.
3. **staging.stg_raw_products** — ETL pipeline that cleanses and stages product master.

### Downstream (Components That Depend on This Output)
1. **marts.fct_orders** — Aggregates line items to order level; depends on this for item-level metrics.
2. **marts.dim_products** — May join to this for product performance metrics.
3. **reporting.revenue_dashboard** — BI tool queries this directly for revenue/margin reporting.
4. **analytics.customer_ltv_model** — Uses this for customer-level revenue aggregation.
5. **finance.margin_analysis** — Consumes for profitability analysis by product/channel.

### External Dependencies
- **Redshift cluster:** Requires active connection and sufficient disk space.
- **IAM permissions:** User running this script must have CREATE/DROP/GRANT privileges on transforms schema.
- **Spectrum external table:** Assumes S3 bucket and Redshift Spectrum configuration are in place.

### Orchestration Assumptions
- **Scheduler:** Not specified in code. Assume Airflow, dbt, or similar orchestration tool triggers this daily/hourly.
- **Error handling:** No try-catch logic; assumes orchestrator handles failures and retries.
- **Idempotency:** DROP TABLE IF EXISTS ensures script is idempotent (safe to re-run).

---

## Maintenance & Monitoring

### Recommended Alerts
- **Row count anomaly:** Alert if row count drops >10% or grows >50% month-over-month (indicates upstream data quality issue).
- **Null rate spike:** Monitor null % for unit_cost, product_name; alert if > 5%.
- **Negative margin:** Query for `margin_pct < 0` daily; indicates pricing or cost data error.
- **Load time SLA:** Alert if script takes > 30 minutes (indicates performance degradation).

### Refresh Frequency
- **Recommended:** Daily full refresh (DROP/CREATE). If latency is critical, consider incremental load on order_date.
- **Retention:** No explicit retention policy in code. Recommend keeping 24 months of history for trend analysis.

### Testing Checklist
- [ ] Verify row count matches expected order item volume.
- [ ] Spot-check margin_pct calculations against manual samples.
- [ ] Confirm no negative net_revenue or margin values (data quality check).
- [ ] Validate discount_pct range (0–100).
- [ ] Check for orphaned line items (order_id not in orders table).
- [ ] Confirm _loaded_at timestamp is recent (within SLA).