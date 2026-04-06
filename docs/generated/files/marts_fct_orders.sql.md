# marts/fct_orders.sql

## Component Overview
- **Layer:** Marts
- **Type:** Fact table (denormalized, aggregated)
- **Schedule:** Not specified in code; infer from dbt/orchestration config
- **Owner:** Not specified in code; likely BI/Analytics team lead

---

## Purpose

`fct_orders` is the primary order-level fact table consumed by BI tools and analysts. It combines order header data, line-item metrics, customer attributes, and session attribution into a single denormalized table optimized for reporting and analysis. This table serves as the single source of truth for order analytics, enabling dashboards, ad-hoc queries, and downstream modeling without requiring analysts to join multiple staging and intermediate tables.

---

## Inputs

| Source Table | Purpose | Why Needed |
|---|---|---|
| **staging.stg_raw_orders** | Order header data (order ID, date, status, channel, payment, shipping, totals) | Provides the order grain and core order attributes; primary join key |
| **staging.stg_raw_customers** | Customer master data (loyalty tier, country, registration date) | Enriches orders with customer context and enables customer lifecycle segmentation |
| **transforms.int_order_items** | Line-item detail with product, quantity, revenue, margin, discount flags | Aggregated to compute order-level metrics (item count, revenue, margin, categories) |
| **transforms.int_customer_sessions** | Session-level data (session ID, referrer, device, duration, pages viewed, purchase flag) | Enables last-click attribution by matching sessions to orders within a 24-hour window |

---

## Outputs

| Target Table | Contents | Downstream Consumers |
|---|---|---|
| **marts.fct_orders** | Denormalized order fact table with 40+ columns spanning order, customer, metrics, and attribution dimensions | BI tools (Tableau, Looker, Power BI), analytics team, executive dashboards, ad-hoc SQL queries, downstream data marts |

---

## Key Business Logic

### 1. **Order-Level Aggregation (order_metrics CTE)**
Aggregates line items from `int_order_items` to the order grain:
- **Item count & product diversity:** `COUNT(*)`, `COUNT(DISTINCT product_id)`, `COUNT(DISTINCT category)` — enables analysis of basket size and cross-category purchasing behavior
- **Revenue & margin:** `SUM(gross_revenue)`, `SUM(net_revenue)`, `SUM(total_cogs)`, `SUM(total_margin)` — provides financial metrics for profitability analysis
- **Average margin %:** `ROUND(AVG(margin_pct), 2)` — normalized to 2 decimals for reporting consistency
- **Discount tracking:** `SUM(CASE WHEN is_discounted THEN 1 ELSE 0 END)` — counts discounted line items to identify promotional impact
- **Category list:** `LISTAGG(DISTINCT category, ', ')` — denormalizes category names for easy filtering in BI tools without requiring joins

**Why:** Eliminates the need for BI analysts to aggregate line items themselves; improves query performance by pre-computing common metrics.

---

### 2. **Session Attribution (order_attribution CTE)**
Identifies the converting session for each order using last-click attribution:
- **Session matching logic:** Joins sessions to orders where:
  - Session user ID matches order customer ID
  - Session start time ≤ order timestamp (session occurred before purchase)
  - Session start time ≥ order timestamp - 24 hours (within 24-hour lookback window)
  - Session has `purchase_count > 0` (only sessions with purchase intent)
- **Deduplication:** `ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY s.session_start DESC)` — selects the most recent qualifying session (last-click model)

**Why:** Enables marketing attribution analysis; 24-hour window balances attribution accuracy with session recency; `purchase_count > 0` filter reduces noise from non-purchase sessions.

---

### 3. **Customer Lifecycle Segmentation**
Calculates tenure and assigns lifecycle stage:
```
customer_tenure_days = DATEDIFF(day, registration_date, order_date)

Lifecycle Stage:
  - New (0-30d)
  - Growing (31-90d)
  - Established (91-365d)
  - Loyal (365d+)
```

**Why:** Enables cohort analysis and retention metrics; thresholds are standard e-commerce benchmarks for customer maturity.

---

### 4. **Order Flags (Boolean Dimensions)**
Encodes business rules as boolean columns for efficient filtering:
- `used_coupon` — TRUE if coupon_code ≠ 'NONE'
- `has_discounted_items` — TRUE if any line item was discounted
- `is_refunded` — TRUE if order_status = 'refunded'
- `is_international` — TRUE if shipping_country ≠ billing_country

**Why:** Pre-computed flags avoid repeated CASE logic in downstream queries; improves BI tool performance.

---

### 5. **Time Dimensions**
Extracts temporal attributes for time-series analysis:
- `day_of_week`, `hour_of_day`, `order_month`, `week_of_year` — enables seasonality and day-part analysis without requiring date functions in BI tools

**Why:** Denormalized time dimensions improve query performance and reduce cognitive load on analysts.

---

### 6. **Filtering Logic**
```sql
WHERE o.order_status NOT IN ('pending_payment', 'fraud_review')
```

Excludes incomplete and flagged orders from the fact table.

**Why:** Prevents inflated revenue metrics and reduces noise; these orders are typically analyzed separately in operational dashboards.

---

## Column Descriptions

| Column | Type | Description | Example Values |
|---|---|---|---|
| **order_id** | VARCHAR | Unique order identifier; distribution key | `ORD-2024-001234` |
| **customer_id** | VARCHAR | Foreign key to customer; enables customer joins | `CUST-5678` |
| **order_date** | DATE | Order date (sort key); used for time-series filtering | `2024-01-15` |
| **order_timestamp** | TIMESTAMP | Precise order creation time; used for session attribution matching | `2024-01-15 14:32:45` |
| **order_status** | VARCHAR | Order fulfillment status | `completed`, `shipped`, `refunded` |
| **order_channel** | VARCHAR | Sales channel | `web`, `mobile_app`, `marketplace` |
| **gross_revenue** | DECIMAL(12,2) | Total revenue before discounts/returns | `149.99` |
| **net_revenue** | DECIMAL(12,2) | Revenue after discounts and returns | `119.99` |
| **total_margin** | DECIMAL(12,2) | Gross profit (net_revenue - cogs) | `45.00` |
| **avg_margin_pct** | DECIMAL(5,2) | Average margin percentage across line items | `37.50` |
| **customer_lifecycle_stage** | VARCHAR | Customer maturity segment based on tenure | `New (0-30d)`, `Loyal (365d+)` |
| **attribution_channel** | VARCHAR | Marketing channel of converting session (last-click) | `organic_search`, `paid_social`, `direct`, `unknown` |
| **conversion_device** | VARCHAR | Device type used in converting session | `desktop`, `mobile`, `tablet`, `unknown` |
| **used_coupon** | BOOLEAN | Whether order applied a coupon code | `TRUE`, `FALSE` |
| **is_international** | BOOLEAN | Whether shipping and billing countries differ | `TRUE`, `FALSE` |
| **_loaded_at** | TIMESTAMP | Data load timestamp for freshness tracking | `2024-01-16 02:15:30` |

---

## Data Quality & Edge Cases

### Null Handling

| Scenario | Handling | Rationale |
|---|---|---|
| **No matching session for order** | `NVL(a.attribution_channel, 'unknown')` | Prevents NULL in BI tools; enables filtering on "unknown" attribution |
| **Customer not found in stg_raw_customers** | LEFT JOIN allows NULL customer attributes | Rare case; order still appears in fact table but without customer context |
| **No line items for order** | INNER JOIN on order_metrics filters these out | Orders without line items are data errors; excluding prevents metric distortion |

### Deduplication Strategy

- **Order grain:** One row per order (enforced by INNER JOIN to order_metrics, which groups by order_id)
- **Session attribution:** `ROW_NUMBER()` with DESC ordering ensures only the most recent session is selected; older sessions are discarded
- **Line items:** Aggregated in CTE; individual line items not preserved (use `int_order_items` for line-level analysis)

### Key Assumptions

1. **Order timestamps are accurate and in UTC** — session attribution logic depends on precise timestamp matching
2. **Customer IDs are consistent** across stg_raw_orders and stg_raw_customers — mismatches result in NULL customer attributes
3. **Session data includes all orders within 24 hours** — if sessions are truncated or delayed, attribution will be incomplete
4. **Coupon code 'NONE' indicates no coupon** — if other null representations exist (NULL, empty string), logic will fail
5. **Order status values are standardized** — filtering on 'pending_payment' and 'fraud_review' assumes these exact values exist
6. **Line items always exist for completed orders** — if orders can exist without line items, INNER JOIN will silently drop them

### Potential Failure Points

| Risk | Impact | Mitigation |
|---|---|---|
| **Upstream schema changes** (e.g., column rename in stg_raw_orders) | Query fails at parse time | Implement column-level lineage monitoring; alert on schema drift |
| **Session data delay** | Attribution incomplete for recent orders | Add SLA monitoring; document expected lag; consider backfill logic |
| **Coupon code format changes** | Coupon flag logic breaks if 'NONE' is replaced with NULL | Add data quality check; update logic if format changes |
| **Customer registration date NULL** | Lifecycle stage calculation fails | Add COALESCE with default date; document assumption |
| **Duplicate line items in int_order_items** | Revenue metrics inflated | Add uniqueness check on (order_id, product_id, line_item_id) in upstream |

---

## Performance Notes

### Join Strategy & Implications

| Join | Type | Key Columns | Performance Impact |
|---|---|---|---|
| **stg_raw_orders → order_metrics** | INNER | order_id | Filters out orders without line items; reduces row count early |
| **stg_raw_orders → stg_raw_customers** | LEFT | customer_id | Preserves all orders; customer attributes may be NULL; no row multiplication |
| **stg_raw_orders → order_attribution** | LEFT | order_id, _rn=1 | Preserves all orders; one session per order (no row multiplication); session lookup is expensive |

### Expensive Operations

1. **Session attribution join** (order_attribution CTE)
   - **Cost:** For each order, scans all sessions for that customer within 24-hour window
   - **Mitigation:** 
     - `int_customer_sessions` should be indexed on (user_id, session_start)
     - 24-hour window limits scan range; consider narrowing if data volume grows
     - `purchase_count > 0` filter reduces candidate sessions
   - **Alternative:** If session data is very large, consider pre-computing attribution in a separate table

2. **LISTAGG aggregation** (categories_purchased)
   - **Cost:** String concatenation across all line items per order; can be slow with many categories
   - **Mitigation:** LISTAGG is efficient in Redshift; acceptable for typical order sizes (< 50 items)
   - **Alternative:** If orders have 100+ items, consider storing categories as JSON or separate dimension table

3. **Full table scan on order_metrics CTE**
   - **Cost:** Aggregates all line items; no pre-filtering
   - **Mitigation:** int_order_items should be filtered upstream (e.g., exclude cancelled items)

### Distribution & Sort Keys

| Key | Type | Rationale |
|---|---|---|
| **order_id** | DISTKEY | Primary query grain; ensures all line-item aggregations co-locate on same node; enables efficient joins on order_id |
| **order_date** | SORTKEY | Most common filter in BI queries (date ranges); sort order enables efficient range scans and compression |

**Implications:**
- Queries filtering by order_date will be fast (zone map pruning)
- Queries filtering by customer_id will require full table scan (not a distribution key)
- If customer-centric queries are common, consider adding customer_id as secondary sort key or creating a separate customer-grain table

### Table Size Estimate

Assuming:
- 10M orders/year
- 40 columns, avg 100 bytes/row
- **Uncompressed:** ~4 GB/year
- **Compressed (Redshift typical 3-4x):** ~1-1.3 GB/year

Redshift can handle this efficiently; no partitioning needed for performance (though could partition by year for maintenance).

---

## Dependencies

### Upstream (Must Run Before This)

| Component | Type | Reason |
|---|---|---|
| **staging.stg_raw_orders** | Staging table | Source of order header data; must be loaded first |
| **staging.stg_raw_customers** | Staging table | Source of customer attributes; must be loaded first |
| **transforms.int_order_items** | Intermediate table | Aggregated in order_metrics CTE; must be computed before this mart |
| **transforms.int_customer_sessions** | Intermediate table | Used for session attribution; must be computed before this mart |

**Orchestration Dependency Graph:**
```
raw_orders → stg_raw_orders ─┐
raw_customers → stg_raw_customers ─┤
raw_order_items → int_order_items ─┼→ fct_orders
raw_sessions → int_customer_sessions ─┘
```

### Downstream (Depends on This Output)

| Component | Type | Usage |
|---|---|---|
| **BI dashboards** (Tableau, Looker, Power BI) | BI tools | Primary consumption; order metrics, customer segmentation, attribution analysis |
| **Executive reports** | Reports | Revenue, margin, customer lifetime value dashboards |
| **Data science models** | ML pipelines | Feature engineering for churn prediction, customer segmentation |
| **Secondary marts** (e.g., fct_customer_orders, fct_marketing_attribution) | Downstream tables | May join or aggregate fct_orders for specialized analysis |
| **Ad-hoc analyst queries** | SQL queries | Analysts query directly for custom analysis |

### External Dependencies

| System | Reference | Purpose |
|---|---|---|
| **Redshift cluster** | Implicit | Execution environment; requires sufficient compute and storage |
| **IAM roles** | `analytics_readers`, `bi_team` | Access control; GRANT statements assume these groups exist |
| **Scheduler** (dbt, Airflow, etc.) | Not specified | Must orchestrate upstream dependencies and this query |

---

## Maintenance & Monitoring

### Recommended Alerts

1. **Row count anomaly:** Alert if row count changes >10% day-over-day (indicates upstream data issue)
2. **NULL rate spike:** Alert if attribution_channel or conversion_device NULL rate exceeds 5% (session data delay)
3. **Load time SLA:** Alert if table creation exceeds 30 minutes (performance degradation)
4. **Stale data:** Alert if _loaded_at is >24 hours old (orchestration failure)

### Refresh Frequency

- **Recommended:** Daily (full refresh)
- **Rationale:** Order data is typically finalized within 24 hours; daily refresh balances freshness with compute cost
- **Alternative:** Incremental refresh on order_date >= CURRENT_DATE - 2 (if upstream supports it)

### Testing Checklist

- [ ] Row count matches expected order volume for date range
- [ ] No duplicate order_ids (grain validation)
- [ ] Revenue totals match source system (reconciliation)
- [ ] Attribution channel distribution is reasonable (no >50% in single channel)
- [ ] Lifecycle stage distribution is reasonable (not all in one bucket)
- [ ] NULL rates are within acceptable thresholds (<5% for key columns)