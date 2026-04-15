# transforms/int_order_items.sql

## Component Overview
- **Layer:** Transforms
- **Type:** Table (materialized)
- **Schedule:** Not specified in code (infer from orchestration config)
- **Owner:** Not specified in code (infer from team documentation)

---

## Purpose

This component enriches raw order line items with product master data and order context to create a single source of truth for item-level financial analysis. It computes critical revenue, cost, and margin metrics at the order-item grain, enabling downstream reporting on profitability, discount impact, and product performance. Analytics teams, finance, and product management consume this table for dashboards, margin analysis, and customer profitability reporting.

---

## Inputs

| Source | Purpose | Criticality |
|--------|---------|-------------|
| **spectrum.raw_order_items** | Raw order line item records including quantity, unit price, discount, and line totals. This component needs it to establish the base transaction fact. | Critical |
| **staging.stg_raw_orders** | Staged order headers containing customer ID, order date, status, channel, country, and payment method. Provides order-level context and customer linkage. | Critical |
| **staging.stg_raw_products** | Staged product master data including SKU, name, category, brand, and unit cost. Needed to compute cost of goods sold (COGS) and margin. | Critical |

---

## Outputs

| Target | Contents | Downstream Consumers |
|--------|----------|---------------------|
| **transforms.int_order_items** | Denormalized order item facts with order, product, and customer dimensions plus computed revenue, COGS, and margin metrics. One row per order line item. | `marts.fct_order_items`, `marts.dim_products`, revenue dashboards, margin analysis reports, customer profitability models |

---

## Key Business Logic

### 1. **Data Validation & Filtering**
```
WHERE oi.order_id IS NOT NULL AND oi.quantity > 0
```
- **Why:** Removes orphaned line items (no parent order) and zero/negative quantities that represent returns, cancellations, or data errors.
- **Impact:** Ensures only valid, billable transactions flow downstream.

### 2. **Type Casting & Precision**
- Order/product IDs cast to `BIGINT` for consistent joins and future-proofing.
- Prices and totals cast to `DECIMAL(10,2)` and `DECIMAL(12,2)` to preserve accounting precision and prevent floating-point rounding errors in financial calculations.
- **Why:** Prevents join failures due to type mismatches and ensures financial accuracy to the cent.

### 3. **Revenue Metrics Hierarchy**
Three revenue tiers are computed:

| Metric | Formula | Business Use |
|--------|---------|--------------|
| **gross_revenue** | `line_total` | Pre-discount revenue; used for top-line reporting |
| **net_revenue** | `line_total × (1 - discount_pct / 100)` | Post-discount revenue; used for actual cash/accrual recognition |
| **cogs** | `quantity × unit_cost` | Cost of goods sold; used to compute margin |

- **Why:** Enables analysis of discount impact and allows finance to reconcile gross vs. net revenue streams.

### 4. **Margin Calculations**
```
gross_margin = line_total - (quantity × unit_cost)
margin_pct = (gross_margin / line_total) × 100
```
- **Why:** Provides both absolute and percentage margin at item level, enabling product-level profitability analysis and identification of low-margin SKUs.
- **Edge case handling:** `margin_pct` defaults to 0 if `line_total ≤ 0` to avoid division by zero.

### 5. **Null Handling for Unit Cost**
```
NVL(p.unit_cost, 0)
```
- **Why:** If product cost is missing, assumes zero cost (best-case margin). This is a **business assumption** that should be validated—missing costs may indicate data quality issues.
- **Risk:** Overstates margin for products with missing cost data.

### 6. **Discount & Product Status Flags**
```
is_discounted = (discount_pct > 0)
is_discontinued_product = (product_status = 'Discontinued')
```
- **Why:** Enables segmentation of discounted vs. full-price sales and identification of revenue from end-of-life products (often a compliance or inventory concern).

### 7. **Join Strategy**
- **INNER JOIN** to `stg_raw_orders`: Ensures every line item has a valid parent order; drops orphaned items.
- **LEFT JOIN** to `stg_raw_products`: Allows line items to exist even if product master is missing (e.g., deleted products), but margin calculations will be incomplete.
- **Why:** Order context is mandatory; product context is optional to handle historical data where products may have been removed from master.

---

## Column Descriptions

| Column | Type | Description | Example |
|--------|------|-------------|---------|
| **order_item_id** | BIGINT | Unique identifier for this line item. Primary key. | 987654321 |
| **order_id** | BIGINT | Foreign key to parent order. Used for aggregation to order level. | 123456 |
| **product_id** | BIGINT | Foreign key to product master. Used for product-level analysis. | 5001 |
| **customer_id** | BIGINT | Foreign key to customer. Enables customer profitability analysis. | 42 |
| **order_date** | DATE | Date order was placed. Used for time-series analysis and period reconciliation. | 2024-01-15 |
| **order_status** | VARCHAR | Order fulfillment status (e.g., 'Completed', 'Cancelled', 'Pending'). Filters for revenue recognition. | Completed |
| **order_channel** | VARCHAR | Sales channel (e.g., 'Web', 'Mobile', 'In-Store'). Used for channel attribution analysis. | Web |
| **sku** | VARCHAR | Stock keeping unit; human-readable product identifier. Used in reports and reconciliation. | SKU-12345 |
| **product_name** | VARCHAR | Product display name. Used in dashboards and customer-facing reports. | Wireless Headphones Pro |
| **category** | VARCHAR | Product category for hierarchical analysis. | Electronics |
| **quantity** | INT | Number of units sold in this line item. | 2 |
| **sold_unit_price** | DECIMAL(10,2) | Price per unit at time of sale. | 149.99 |
| **discount_pct** | DECIMAL(5,2) | Discount percentage applied (0–100). | 10.00 |
| **net_revenue** | DECIMAL(12,2) | Revenue after discount. Used for revenue recognition and P&L. | 269.98 |
| **gross_margin** | DECIMAL(12,2) | Absolute margin (revenue minus COGS). Used for profitability analysis. | 134.99 |
| **margin_pct** | DECIMAL(5,2) | Margin as percentage of revenue. Used for product performance ranking. | 50.00 |
| **is_discounted** | BOOLEAN | Flag indicating whether any discount was applied. Used for segmentation. | true |
| **_loaded_at** | TIMESTAMP | Timestamp when this row was loaded into the table. Used for data freshness monitoring. | 2024-01-16 10:30:00 |

---

## Data Quality & Edge Cases

### Null Handling

| Scenario | Handling | Risk |
|----------|----------|------|
| **Missing `unit_cost`** | `NVL(unit_cost, 0)` → assumes zero cost | Overstates margin; should trigger data quality alert |
| **Missing `discount_pct`** | `NVL(discount_pct, 0)` → assumes no discount | Understates discount impact if data is sparse |
| **NULL `product_id`** | LEFT JOIN allows NULL; product fields will be NULL | Orphaned line items; should be investigated |
| **NULL `order_id`** | Filtered out in `order_items` CTE | No impact; these records are dropped |

### Deduplication Strategy

- **No explicit deduplication.** Assumes `spectrum.raw_order_items` is already deduplicated at the `order_item_id` level.
- **Risk:** If raw layer contains duplicate line items, they will propagate here. Recommend adding a `ROW_NUMBER()` dedup step if duplicates are suspected.

### Key Assumptions

1. **Unit cost is static:** Assumes `p.unit_cost` represents the cost at time of sale. If costs are versioned, this may compute incorrect historical margins.
2. **Discount is percentage-based:** Assumes `discount_pct` is always a percentage (0–100). If absolute discounts exist, formula breaks.
3. **Line totals are pre-discount:** Assumes `oi.line_total` is the gross amount before discount is applied. If it's already discounted, `net_revenue` calculation is wrong.
4. **Product status is current:** `is_discontinued_product` uses current product status, not historical status at time of sale. May misclassify old orders.
5. **No multi-currency:** All prices assumed to be in a single currency. If `billing_country` implies multi-currency, conversion logic is missing.

### What Could Break

- **Upstream schema changes:** If `spectrum.raw_order_items` renames `unit_price` or `line_total`, this query fails.
- **Missing product records:** If a product is deleted from `stg_raw_products` after an order, that order's margin will be incomplete (cost = 0).
- **Negative quantities:** Current filter allows `quantity > 0`, but returns/credits with negative quantities are dropped. If return tracking is needed, this logic must change.
- **Discount exceeding 100%:** No validation; if `discount_pct > 100`, `net_revenue` becomes negative.
- **Stale staging tables:** If `stg_raw_orders` or `stg_raw_products` are not refreshed before this runs, enrichment will use stale data.

---

## Performance Notes

### Distribution & Sort Keys

```sql
DISTKEY(order_id)
SORTKEY(order_date, order_id)
```

- **DISTKEY(order_id):** Distributes rows across cluster nodes by order ID. Optimizes joins to `stg_raw_orders` (also keyed on `order_id`) and aggregations by order.
- **SORTKEY(order_date, order_id):** Sorts within each node by date, then order ID. Optimizes time-series queries and range scans on order_date.
- **Why:** Most downstream queries filter by date range and aggregate by order/customer. This key design minimizes data movement during joins and scans.

### Join Strategy

| Join | Type | Cost | Notes |
|------|------|------|-------|
| `order_items` → `stg_raw_orders` | INNER | Medium | Both tables keyed on `order_id`; should be a hash join with minimal shuffle. |
| `order_items` → `stg_raw_products` | LEFT | Medium-High | If `stg_raw_products` is large and not keyed on `product_id`, this may require a full table scan. Consider adding a `product_id` index. |

### Potential Bottlenecks

1. **LEFT JOIN to products:** If `stg_raw_products` is not indexed on `product_id`, Redshift may scan the entire table for each order item. **Mitigation:** Ensure `stg_raw_products` has a `product_id` distribution key.
2. **DECIMAL arithmetic:** Computing `margin_pct` involves division for every row. **Impact:** Negligible for typical order volumes (<10M rows), but monitor if table grows beyond 100M rows.
3. **GETDATE() evaluation:** Called once per row. **Impact:** Minimal; Redshift optimizes this, but consider computing once and passing as a parameter if performance degrades.

### Table Size Expectations

- **Grain:** One row per order line item.
- **Typical volume:** 10–100M rows (scales with order volume).
- **Estimated size:** ~500 MB–5 GB (depending on order history depth).
- **Refresh frequency:** Infer from orchestration config; typically daily or hourly.

---

## Dependencies

### Upstream (Must Run Before This Component)

| Component | Purpose | Frequency |
|-----------|---------|-----------|
| **staging.stg_raw_orders** | Stages raw order headers. Must be refreshed before this transform to ensure current order context. | Daily or per-batch |
| **staging.stg_raw_products** | Stages product master. Must be refreshed before this transform to ensure current product costs and status. | Daily or per-batch |
| **spectrum.raw_order_items** | Raw order items from source system (e.g., ERP, e-commerce platform). Must be loaded before this transform. | Daily or per-batch |

### Downstream (Depends on This Component)

| Component | Purpose | Frequency |
|-----------|---------|-----------|
| **marts.fct_order_items** | Fact table for order item analytics. Consumes this transform as source. | Daily or per-batch |
| **marts.dim_products** | Product dimension. May consume product-level aggregations from this table. | Daily or per-batch |
| **Revenue Dashboard** | Executive dashboard showing revenue, margin, and discount trends. Queries this table directly or via marts. | Real-time or hourly |
| **Margin Analysis Report** | Finance report on product and customer profitability. Depends on accurate margin calculations. | Weekly or monthly |
| **Customer Profitability Model** | Aggregates order items by customer to compute lifetime value and segment. | Monthly |

### External Dependencies

- **None detected in code.** No API calls, external configs, or third-party systems referenced.
- **Implicit:** Assumes Redshift cluster is running and `spectrum` schema is configured for Redshift Spectrum (external S3 data).

---

## Maintenance & Monitoring

### Recommended Alerts

- **NULL unit_cost rate > 5%:** Indicates product master data quality issue.
- **Negative net_revenue:** Indicates discount > 100% or data error.
- **Table load time > 2× baseline:** Indicates upstream data volume spike or join performance degradation.
- **Row count variance > 20% day-over-day:** Indicates upstream data anomaly or filtering logic change.

### Testing Checklist

- [ ] Verify `order_item_id` is unique (no duplicates).
- [ ] Verify `net_revenue ≤ gross_revenue` for all rows.
- [ ] Verify `margin_pct` is between 0 and 100 for non-negative revenue.
- [ ] Spot-check margin calculations against source system.
- [ ] Verify no orphaned items (all `order_id` exist in `stg_raw_orders`).
- [ ] Verify `_loaded_at` is current (within last refresh window).