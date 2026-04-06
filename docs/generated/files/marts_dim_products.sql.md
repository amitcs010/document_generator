# marts/dim_products.sql

## Component Overview
- **Layer:** Marts
- **Type:** Table (Redshift)
- **Schedule:** Not specified in code (infer from orchestration layer)
- **Owner:** Not specified in code (recommend: Analytics Engineering team)

---

## Purpose

`dim_products` is the authoritative product dimension table consumed by BI tools and analyst queries. It enriches core product attributes (SKU, category, pricing) with historical sales performance metrics and real-time inventory status, enabling business stakeholders to analyze product profitability, sales velocity, and market performance without requiring joins to transactional tables.

---

## Inputs

| Source | Purpose | Criticality |
|--------|---------|-------------|
| **staging.stg_raw_products** | Provides current product master data: SKU, name, category, pricing, cost, weight, supplier, launch date, and current inventory levels. This is the single source of truth for product attributes. | Critical |
| **transforms.int_order_items** | Provides historical order-level transaction data (quantity, revenue, margin, discount, order dates, customer IDs). Used to calculate lifetime sales metrics and performance tiers. Filtered to exclude cancelled and fraud orders. | Critical |

---

## Outputs

| Target | Contents | Consumers |
|--------|----------|-----------|
| **marts.dim_products** | 30+ columns combining product master data with aggregated sales KPIs, inventory status classifications, and performance rankings. One row per product. | BI tools (Tableau, Looker), SQL analysts, revenue reporting dashboards, product performance scorecards, inventory management systems |

---

## Key Business Logic

### 1. **Sales Performance Aggregation** (CTE: `product_sales`)
Aggregates all historical order transactions by product, excluding cancelled and fraud orders. Calculates:
- **Total units sold & revenue:** Lifetime volume and value per product
- **Gross margin:** Cumulative profit contribution
- **Customer reach:** Distinct customer count indicates market penetration
- **Order frequency:** Count of distinct orders shows repeat purchase patterns
- **Price realization:** Average selling price vs. list price reveals actual discount depth
- **Sales recency:** First and last sale dates identify product lifecycle stage

**Why:** Enables analysts to quickly assess product health without querying transactional tables; supports cohort analysis and performance ranking.

### 2. **Margin Calculation** (Derived Column)
```
list_margin_pct = (unit_price - unit_cost) / unit_price * 100
```
Calculates theoretical margin at list price. Compared against actual `avg_discount_given` to identify margin erosion.

**Why:** Separates pricing strategy (list margin) from execution (actual margin after discounts), revealing sales team behavior and competitive pressure.

### 3. **Inventory Status Classification** (CASE Statement)
Categorizes products into four tiers based on current stock:
- **Out of Stock:** inventory_count ≤ 0 (triggers reorder alerts)
- **Low Stock:** 1–9 units (risk of stockout)
- **Normal:** 10–99 units (healthy buffer)
- **Well Stocked:** 100+ units (potential overstock risk)

**Why:** Provides operational visibility for supply chain and warehouse teams; flags products requiring immediate attention.

### 4. **Sales Recency** (Derived Column)
```
days_since_last_sale = DATEDIFF(day, last_sold_date, GETDATE())
```
Measures staleness of product in market. High values indicate:
- Discontinued products still in inventory
- Seasonal items in off-season
- Dead SKUs requiring clearance

**Why:** Identifies slow-moving inventory and products at risk of obsolescence.

### 5. **Revenue-Based Performance Ranking** (Window Function)
```
revenue_quartile = NTILE(4) OVER (ORDER BY total_revenue DESC)
```
Ranks all products into four equal-sized groups (Q1 = top 25% by revenue, Q4 = bottom 25%).

**Why:** Enables Pareto analysis (80/20 rule); supports portfolio segmentation for marketing spend allocation and inventory investment decisions.

### 6. **Left Join Strategy**
Products without sales history (new products, never-ordered SKUs) retain all master attributes but show zero/null sales metrics. This is intentional—ensures all active products appear in the dimension even if not yet sold.

**Why:** Supports inventory planning and new product launch tracking; prevents orphaned products from disappearing from reports.

### 7. **Null Handling with NVL()**
Sales metrics default to 0 for unsold products; `avg_selling_price` defaults to `unit_price` (list price) when no sales exist.

**Why:** Prevents NULL propagation in downstream calculations; ensures BI tools can safely aggregate without filtering.

---

## Column Descriptions

| Column | Type | Description | Example |
|--------|------|-------------|---------|
| **product_id** | INT | Unique product identifier (primary key). | 42857 |
| **sku** | VARCHAR | Stock keeping unit—human-readable product code. | `WIDGET-BLU-LG-001` |
| **product_name** | VARCHAR | Marketing name of product. | `Premium Blue Widget Large` |
| **category** | VARCHAR | Top-level product category. | `Widgets` |
| **subcategory** | VARCHAR | Secondary classification. | `Premium` |
| **brand** | VARCHAR | Brand/manufacturer. | `WidgetCorp` |
| **current_list_price** | DECIMAL(10,2) | Current MSRP/list price in USD. | 49.99 |
| **unit_cost** | DECIMAL(10,2) | COGS per unit. | 15.00 |
| **list_margin_pct** | DECIMAL(5,2) | Theoretical margin % at list price. | 69.94 |
| **total_units_sold** | BIGINT | Lifetime units sold (excludes cancelled/fraud orders). | 15847 |
| **total_revenue** | DECIMAL(15,2) | Lifetime gross revenue in USD. | 789,234.50 |
| **total_margin** | DECIMAL(15,2) | Lifetime gross profit in USD. | 234,567.89 |
| **order_count** | INT | Number of distinct orders containing this product. | 3,421 |
| **unique_customers** | INT | Number of distinct customers who purchased this product. | 2,156 |
| **first_sold_date** | DATE | Date of first recorded sale. | 2022-03-15 |
| **last_sold_date** | DATE | Date of most recent sale. | 2024-01-28 |
| **avg_selling_price** | DECIMAL(10,2) | Average realized price per unit (after discounts). | 47.50 |
| **avg_discount_given** | DECIMAL(5,2) | Average discount % applied across all orders. | 4.98 |
| **inventory_status** | VARCHAR | Operational stock level classification. | `Well Stocked`, `Low Stock` |
| **days_since_last_sale** | INT | Days elapsed since last transaction. | 14 |
| **revenue_quartile** | INT | Performance tier (1=top 25%, 4=bottom 25%). | 1 |
| **_loaded_at** | TIMESTAMP | Table refresh timestamp (UTC). | 2024-02-15 14:32:00 |

---

## Data Quality & Edge Cases

### Null Handling
| Scenario | Handling | Risk |
|----------|----------|------|
| Product never sold | Sales metrics = 0; `avg_selling_price` = list price | Low—intentional; ensures all products visible |
| `last_sold_date` is NULL | `days_since_last_sale` = NULL; may cause issues in downstream filters | **Medium**—recommend adding COALESCE in dependent queries |
| `unit_price` = 0 | `list_margin_pct` = NULL (NULLIF prevents division by zero) | Low—edge case; indicates data quality issue upstream |
| Cancelled/fraud orders excluded | Sales metrics exclude ~X% of transactions | **Medium**—verify exclusion logic aligns with business definition of "valid" sales |

### Deduplication Strategy
- **Product level:** One row per `product_id` (enforced by GROUP BY in CTE)
- **Order level:** Aggregated via SUM/COUNT(DISTINCT) to avoid double-counting if `int_order_items` contains multiple line items per order
- **No deduplication of products themselves:** If `stg_raw_products` contains duplicates, this query will produce duplicates. **Recommend validating upstream uniqueness.**

### Key Assumptions
1. **`stg_raw_products` has unique product_id:** No validation in this query; duplicates will propagate
2. **`int_order_items` is fully deduplicated:** Assumes one row per order line item; if contains duplicates, sales metrics will inflate
3. **Order status values are consistent:** Hardcoded filter on `('cancelled', 'fraud_review')` assumes these exact values exist; typos or new statuses will be included unintentionally
4. **`order_date` is always populated:** NULL dates would be silently excluded from date range calculations
5. **Inventory count is current as of table load:** No historical tracking; reflects point-in-time snapshot
6. **GETDATE() is UTC:** Timestamp assumes Redshift cluster timezone is UTC; verify if business operates in different timezone

### What Could Break

| Change | Impact | Mitigation |
|--------|--------|-----------|
| New order status added (e.g., `pending_fulfillment`) | Status would be included in sales metrics if not in exclusion list | Add to WHERE clause; document all valid statuses |
| `int_order_items` schema changes (column renamed/removed) | Query fails at runtime | Add column existence checks in pre-flight validation |
| `stg_raw_products` contains duplicate product_ids | Dimension contains duplicate rows; BI tools may double-count metrics | Add DISTINCT or validate upstream uniqueness |
| Negative inventory counts | `inventory_status` classification still works but may misclassify | Add data quality check; consider CASE for negative values |
| `unit_price` or `unit_cost` becomes NULL | Margin calculation returns NULL; `avg_selling_price` defaults to NULL | Add NOT NULL constraints upstream or add COALESCE |

---

## Performance Notes

### Join Strategy
```sql
FROM staging.stg_raw_products p
LEFT JOIN product_sales ps ON p.product_id = ps.product_id
```
- **Type:** LEFT JOIN (all products retained, even if no sales)
- **Join key:** `product_id` (likely indexed in both tables)
- **Implication:** If `stg_raw_products` has 50K products and `int_order_items` has 10M rows, the CTE aggregation is the expensive operation, not the join
- **Recommendation:** Ensure `int_order_items.product_id` is indexed

### Expensive Operations
1. **CTE Aggregation (`product_sales`):** 
   - Scans entire `int_order_items` table (10M+ rows typical)
   - Performs GROUP BY on `product_id` (requires sort or hash aggregate)
   - **Cost:** O(n log n) for sort-based aggregation
   - **Mitigation:** If `int_order_items` is already sorted by `product_id`, Redshift may use streaming aggregate (faster)

2. **Window Function (`NTILE`):**
   - Requires full sort of all products by `total_revenue DESC`
   - **Cost:** O(n log n) where n = number of products (~50K)
   - **Mitigation:** Acceptable; only runs once per refresh; not a bottleneck

3. **DATEDIFF Calculation:**
   - Runs for every row; minimal cost
   - **Mitigation:** None needed

### Distribution & Sort Keys
```sql
DISTSTYLE ALL
SORTKEY(product_id)
```
- **DISTSTYLE ALL:** Entire table replicated to all nodes (appropriate for dimension table <100MB)
  - **Benefit:** No network traffic for joins; fast local lookups
  - **Cost:** Storage overhead; slower INSERT/UPDATE
  - **Recommendation:** Acceptable for product dimension; verify table size remains <100MB

- **SORTKEY(product_id):** Physically orders rows by product_id
  - **Benefit:** Range queries on `product_id` are fast; JOIN performance improved
  - **Recommendation:** Good choice; aligns with primary key and common filter

### Estimated Runtime
- **Full refresh:** 2–5 minutes (depends on `int_order_items` size and cluster size)
- **Bottleneck:** CTE aggregation of order items
- **Recommendation:** If refresh time exceeds SLA, consider materializing `product_sales` as separate table or incrementally updating only changed products

---

## Dependencies

### Upstream (Must Run Before This)
| Component | Purpose | Frequency |
|-----------|---------|-----------|
| **staging.stg_raw_products** | Loads raw product master data from source system (ERP/PIM). Must be refreshed before this query runs. | Daily or real-time |
| **transforms.int_order_items** | Transforms raw order transactions into denormalized order-item facts with revenue/margin calculations. Must be complete before aggregation. | Daily (after order transactions load) |

### Downstream (Depends on This Output)
| Component | Usage | Frequency |
|-----------|-------|-----------|
| **BI Dashboards (Tableau/Looker)** | Product performance scorecards, sales by category, inventory reports | Real-time queries |
| **Revenue Reporting** | Monthly/quarterly product revenue summaries | Daily refresh |
| **Inventory Management System** | Stock level alerts, reorder recommendations | Real-time queries |
| **Product Analytics Queries** | Ad-hoc analyst queries on product profitability, customer segmentation | On-demand |
| **Potential downstream marts** | `fct_product_daily_sales`, `rpt_product_performance` may join to this dimension | Depends on data model |

### External Dependencies
| Dependency | Type | Impact |
|------------|------|--------|
| **Redshift cluster availability** | Infrastructure | If cluster down, table cannot be refreshed or queried |
| **Source ERP/PIM system** | Data source | If source unavailable, `stg_raw_products` stale; dimension reflects old product data |
| **Analytics reader groups** | IAM/Security | GRANT statements assume `analytics_readers` and `bi_team` groups exist in Redshift |

---

## Maintenance & Monitoring

### Recommended Alerts
- **Refresh duration >10 minutes:** Indicates performance degradation or data volume growth
- **NULL `last_sold_date` count >5% of products:** Indicates many unsold products; may signal data quality issue
- **`days_since_last_sale` >365 for >20% of products:** Indicates stale inventory; may require clearance strategy
- **Table size >200MB:** Exceeds DISTSTYLE ALL recommendation; consider switching to KEY distribution

### Refresh Schedule Recommendation
- **Frequency:** Daily (after `int_order_items` completes)
- **Time window:** Off-peak hours (e.g., 2–4 AM UTC)
- **Retention:** Keep current snapshot only (no historical versions)

### Documentation Gaps to Address
- Owner/team responsible for this table
- Refresh schedule and SLA
- Data retention policy
- Escalation contact for failures
- Business glossary definitions (e.g., what constitutes "fraud_review" status)