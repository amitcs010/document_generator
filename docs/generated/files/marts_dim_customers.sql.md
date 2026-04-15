# marts/dim_customers.sql

## Component Overview
- **Layer:** Marts
- **Type:** Table (materialized dimension)
- **Schedule:** Not specified in code; infer from dbt/orchestration config
- **Owner:** Not specified in code; infer from team documentation

---

## Purpose

This component builds a comprehensive **customer master dimension** that enriches raw customer attributes with behavioral metrics, RFM segmentation, and churn risk scoring. It serves as the single source of truth for customer analytics, enabling BI tools and analysts to perform customer lifetime value analysis, segmentation-based reporting, and retention campaigns without recalculating metrics on-the-fly.

The table is designed to support use cases like:
- Customer segmentation dashboards (Champions vs. At Risk cohorts)
- Churn prediction and retention workflows
- Marketing campaign targeting and personalization
- Executive reporting on customer health and lifetime value

---

## Inputs

| Source | Purpose | Criticality |
|--------|---------|-------------|
| **marts.fct_orders** | Provides transactional order history (order dates, revenue, refunds, channels, payment methods) needed to calculate recency, frequency, monetary value, and customer behavior metrics. | Critical |
| **staging.stg_raw_customers** | Provides customer master data (identifiers, contact info, registration date, loyalty tier, marketing preferences, location, login activity). | Critical |

---

## Outputs

| Target | Contents | Downstream Consumers |
|--------|----------|---------------------|
| **marts.dim_customers** | Denormalized customer dimension with 40+ columns including demographics, order history, RFM scores, segmentation, and churn risk. Distributed by `customer_id` and sorted for fast lookups. | BI tools (Tableau, Looker), analytics team, marketing automation platforms, customer success dashboards, churn prediction models |

---

## Key Business Logic

### 1. **Customer Order Aggregation** (`customer_orders` CTE)
Aggregates all transactional data from `fct_orders` to the customer level:
- **Total orders, lifetime revenue, lifetime margin:** Measures customer value and engagement depth
- **First/last order dates:** Establish customer lifecycle windows
- **Average order value:** Indicates purchase behavior and segment quality
- **Active months:** Counts distinct order months to measure engagement consistency (using `APPROXIMATE COUNT DISTINCT` for performance)
- **Refund count:** Flags problematic customers or product quality issues
- **Preferred channel & payment method:** Uses `MODE()` to identify dominant customer behavior patterns for personalization

**Why:** Reduces millions of order rows to one row per customer, enabling efficient joins and downstream analytics.

---

### 2. **RFM Scoring** (`rfm` CTE)
Calculates three behavioral dimensions using percentile-based scoring:

| Dimension | Calculation | Business Meaning |
|-----------|-------------|------------------|
| **Recency (R)** | Days since last order, ranked 1–5 (ascending) | How recently the customer engaged; lower recency = higher score |
| **Frequency (F)** | Total order count, ranked 1–5 (ascending) | How often they purchase; more orders = higher score |
| **Monetary (M)** | Lifetime revenue, ranked 1–5 (ascending) | How much they've spent; higher spend = higher score |

**Why:** RFM is a proven segmentation framework. Percentile-based scoring (NTILE) ensures balanced cohorts and is robust to outliers. Scores range 1–5 per dimension, enabling intuitive business rules.

---

### 3. **Customer Segmentation Logic**
Applies hierarchical business rules to assign customers to actionable segments:

| Segment | Rule | Action |
|---------|------|--------|
| **Never Purchased** | No order history | Exclude from retention; focus on activation |
| **Champions** | R ≥ 4, F ≥ 4, M ≥ 4 | VIP treatment; upsell/cross-sell opportunities |
| **Loyal Customers** | R ≥ 4, F ≥ 3 | Retain; reward loyalty programs |
| **New Customers** | R ≥ 4, F ≤ 2 | Nurture; reduce friction; encourage repeat purchase |
| **Potential Loyalists** | R ≥ 3, F ≥ 3 | Engage; personalize; build habit |
| **At Risk** | R ≤ 2, F ≥ 3 | Win-back campaigns; identify pain points |
| **Can't Lose Them** | R ≤ 2, F ≤ 2, M ≥ 3 | High-value but dormant; urgent re-engagement |
| **Hibernating** | R ≤ 2, F ≤ 2, M < 3 | Low priority; cost-effective reactivation only |

**Why:** Enables marketing and product teams to tailor strategies by cohort. Rules are ordered by business priority (Champions first).

---

### 4. **Churn Risk Classification**
Assigns risk levels based on days since last purchase:

| Risk Level | Days Since Last Order | Implication |
|------------|----------------------|-------------|
| **no_purchase** | Never ordered | Not yet a customer; acquisition focus |
| **active** | ≤ 30 days | Engaged; low risk |
| **low_risk** | 31–90 days | Slight engagement gap; gentle re-engagement |
| **medium_risk** | 91–180 days | Significant inactivity; targeted campaigns |
| **high_risk** | > 180 days | Likely churned; intensive win-back or accept loss |

**Why:** Provides a simple, actionable metric for retention prioritization. Thresholds are business-defined (adjust as needed based on industry/product).

---

### 5. **Refund Rate Calculation**
Computes refund rate as a percentage:
```
refund_rate_pct = (refund_count / total_orders) * 100
```
Handles division by zero by returning 0 for customers with no orders.

**Why:** Identifies problematic customers (high refund rates may indicate fraud, dissatisfaction, or product misalignment) and product quality issues.

---

### 6. **Null Handling Strategy**
Uses `NVL()` extensively to ensure:
- Customers with no orders get 0 for counts/sums (not NULL)
- RFM scores default to 1 (lowest tier) if missing
- Categorical fields default to 'none' if missing
- Prevents NULL propagation in downstream calculations

**Why:** Ensures all customers appear in reports and aggregations don't silently drop rows.

---

## Column Descriptions

### Core Identifiers & Demographics
| Column | Type | Description | Example |
|--------|------|-------------|---------|
| **customer_id** | INT | Unique customer identifier; distribution key | `12345` |
| **email_hash** | VARCHAR | SHA-256 hash of email for privacy compliance | `a1b2c3d4...` |
| **email_domain** | VARCHAR | Domain extracted from email for cohort analysis | `gmail.com` |
| **first_name_masked** | VARCHAR | First name with PII masking (e.g., first letter + asterisks) | `J***` |
| **country** | VARCHAR | Customer's billing country | `US` |
| **state** | VARCHAR | State/province | `CA` |
| **registration_date** | DATE | Account creation date | `2022-01-15` |
| **marketing_opt_in** | BOOLEAN | Consent for marketing communications | `true` |

### Order History & Engagement
| Column | Type | Description | Example |
|--------|------|-------------|---------|
| **total_orders** | INT | Lifetime count of orders | `42` |
| **lifetime_revenue** | DECIMAL(18,2) | Total gross revenue from customer | `5,234.50` |
| **lifetime_margin** | DECIMAL(18,2) | Total profit margin from customer | `1,234.50` |
| **first_order_date** | DATE | Date of first purchase | `2022-02-01` |
| **last_order_date** | DATE | Date of most recent purchase | `2024-01-20` |
| **avg_order_value** | DECIMAL(18,2) | Mean revenue per order | `124.63` |
| **active_months** | INT | Count of distinct months with orders | `18` |
| **refund_count** | INT | Number of refunded orders | `2` |
| **total_units_purchased** | INT | Cumulative quantity of items ordered | `156` |
| **preferred_channel** | VARCHAR | Most common order channel (mode) | `web`, `mobile`, `phone` |

### RFM Scores & Segmentation
| Column | Type | Description | Example |
|--------|------|-------------|---------|
| **recency_score** | INT | Percentile rank (1–5) of days since last order; 5 = most recent | `5` |
| **frequency_score** | INT | Percentile rank (1–5) of order count; 5 = most frequent | `4` |
| **monetary_score** | INT | Percentile rank (1–5) of lifetime revenue; 5 = highest spender | `3` |
| **rfm_total** | INT | Sum of three RFM scores; range 3–15 | `12` |
| **customer_segment** | VARCHAR | Behavioral segment for targeting | `Champions`, `At Risk`, `Hibernating` |
| **churn_risk** | VARCHAR | Risk classification for retention prioritization | `active`, `high_risk`, `no_purchase` |
| **refund_rate_pct** | DECIMAL(5,2) | Percentage of orders refunded | `4.76` |

### Metadata
| Column | Type | Description | Example |
|--------|------|-------------|---------|
| **_loaded_at** | TIMESTAMP | ETL load timestamp; used for incremental refresh tracking | `2024-01-21 03:45:00` |

---

## Data Quality & Edge Cases

### Null Handling
- **Customers with no orders:** All order metrics default to 0; RFM scores default to 1; segment = 'Never Purchased'
- **Missing preferred channel/payment:** Defaults to 'none' (not NULL) to avoid NULL comparisons in downstream filters
- **Missing loyalty tier:** Preserved as-is from source; may be NULL if not populated

**Risk:** If `fct_orders` is empty or corrupted, all customers will appear as "Never Purchased" with zero metrics. Validate row counts post-load.

---

### Deduplication Strategy
- **No explicit deduplication:** Assumes `staging.stg_raw_customers` contains one row per `customer_id`
- **Order aggregation:** `GROUP BY customer_id` in `customer_orders` CTE naturally deduplicates orders

**Risk:** If `stg_raw_customers` has duplicate customer records, the LEFT JOIN will produce duplicate rows in output. Add a `DISTINCT` or validate source uniqueness.

---

### Assumptions About Upstream Data
1. **`fct_orders.order_date` is always populated** — used for recency and first/last order calculations
2. **`fct_orders.gross_revenue` and `total_margin` are numeric and non-negative** — no validation for negative revenue (refunds may be represented as negative values)
3. **`fct_orders.is_refunded` is a boolean flag** — assumes binary representation of refund status
4. **`stg_raw_customers.customer_id` is unique** — no handling for duplicate customer records
5. **`GETDATE()` returns current UTC timestamp** — recency calculations assume consistent timezone
6. **`MODE()` function exists and is deterministic** — Redshift-specific; may behave unexpectedly with ties (returns arbitrary value)

---

### What Could Break
| Scenario | Impact | Mitigation |
|----------|--------|-----------|
| `fct_orders` contains future-dated orders | Negative recency values; incorrect churn risk | Add validation: `WHERE order_date <= GETDATE()` |
| Duplicate customer IDs in `stg_raw_customers` | Output rows multiply; metrics duplicated | Add `DISTINCT ON (customer_id)` or validate source |
| `MODE()` function returns NULL on ties | Preferred channel/payment = NULL (not 'none') | Use `COALESCE(MODE(...), 'none')` explicitly |
| `fct_orders` is empty or truncated | All customers marked "Never Purchased" | Add row count validation; alert if < expected baseline |
| `stg_raw_customers` missing recent signups | New customers not in dimension | Validate `registration_date` range; check source freshness |
| Timezone mismatch between systems | Recency calculations off by 1+ days | Standardize to UTC; document timezone assumptions |

---

## Performance Notes

### Join Strategy
```
staging.stg_raw_customers (LEFT JOIN) customer_orders (LEFT JOIN) rfm
```
- **Left outer joins:** Preserves all customers even if they have no orders (important for acquisition funnel analysis)
- **Join keys:** `customer_id` (simple, non-nullable, indexed in source tables)
- **Implication:** If `stg_raw_customers` has 1M rows and `fct_orders` has 100M rows, the aggregation reduces to 1M rows before joining back, minimizing Cartesian product risk

---

### Expensive Operations
| Operation | Cost | Mitigation |
|-----------|------|-----------|
| **`APPROXIMATE COUNT DISTINCT order_month`** | O(n) scan of `fct_orders` | Uses Redshift's HyperLogLog approximation; acceptable for "active_months" metric (not exact, but fast) |
| **`MODE() WITHIN GROUP`** | O(n log n) sort per customer | Requires full sort of order channels/payments per customer; can be slow on large order volumes; consider caching if this becomes bottleneck |
| **`NTILE(5) OVER (...)`** | O(n log n) window function | Requires full sort of all customers by recency/frequency/monetary; acceptable for 1M+ customers but monitor execution time |
| **`DROP TABLE IF EXISTS`** | Metadata operation | Fast; no data movement |

---

### Partitioning & Distribution
```sql
DISTKEY(customer_id)
SORTKEY(customer_id)
```

**Distribution Key (`customer_id`):**
- Ensures rows for the same customer co-locate on the same node
- Optimizes joins on `customer_id` (no data redistribution needed)
- Assumes relatively even distribution of orders across customers (if a few customers have 90% of orders, this skews node load)

**Sort Key (`customer_id`):**
- Enables fast range scans when filtering by customer ID (e.g., `WHERE customer_id IN (...)`)
- Improves compression and I/O efficiency
- Supports efficient incremental updates if this table is refreshed daily

**Implication:** This table is optimized for customer-centric queries (e.g., "get all metrics for customer X"). If queries frequently filter by segment or churn_risk, consider adding a secondary sort key or creating a secondary index.

---

### Table Size Estimate
- **Rows:** ~1 row per unique customer (e.g., 1M–10M for mid-market SaaS)
- **Columns:** 40+ columns, mostly INT/VARCHAR/DATE
- **Estimated size:** 500MB–5GB (uncompressed); Redshift compression typically 3–5x, so 100MB–1GB on disk
- **Refresh time:** 5–30 minutes depending on `fct_orders` size and cluster resources

---

### Optimization Opportunities
1. **Materialized views for RFM scores:** If RFM is recalculated frequently, pre-compute and store separately to avoid re-sorting
2. **Incremental refresh:** Instead of `DROP TABLE`, use `DELETE + INSERT` for customers with recent order activity
3. **Caching preferred channel/payment:** If `MODE()` is slow, pre-compute in a separate table and join
4. **Partition by registration_date cohort:** If queries often filter by "customers acquired in Q4 2023", add a partition key

---

## Dependencies

### Upstream (Must Run Before This)
| Component | Reason | Frequency |
|-----------|--------|-----------|
| **marts.fct_orders** | Provides transactional order data; must be fully loaded and aggregated | Daily (or per business cycle) |
| **staging.stg_raw_customers** | Provides customer master data; must be fresh and deduplicated | Daily or real-time sync |
| **Redshift cluster** | Must be running and accessible; sufficient compute for window functions | Always |

---

### Downstream (Depends on This Output)
| Component | Usage | Frequency |
|-----------|-------|-----------|
| **BI dashboards** (Tableau, Looker, Power BI) | Customer segmentation, lifetime value, churn risk reporting | Real-time or hourly refresh |
| **Marketing automation** (Segment, Marketo, HubSpot) | Audience targeting based on segment and churn risk | Daily sync via API |
| **Churn prediction models** | Feature engineering; input to ML pipelines | Daily or weekly retraining |
| **Customer success workflows** | Identify at-risk customers for outreach; prioritize high-value accounts | Real-time or daily |
| **Finance/revenue analytics** | Customer cohort analysis, LTV trends, retention metrics | Monthly or quarterly |
| **Product analytics** | Behavioral segmentation; feature adoption by customer tier | Weekly or monthly |

---

### External Dependencies
- **Redshift SQL dialect:** Code uses Redshift-specific functions (`GETDATE()`, `DATEDIFF()`, `NTILE()`, `MODE()`, `APPROXIMATE COUNT DISTINCT`). Not portable to other SQL engines without modification.
- **Timezone:** Assumes `GETDATE()` returns UTC. If Redshift is configured for a different timezone, recency calculations will be offset.
- **Permissions:** Requires `SELECT` on `marts.fct_orders` and `staging.stg_raw_customers`; `CREATE TABLE` on `marts` schema; `GRANT` privileges to `analytics_readers` and `bi_team` groups.

---

## Maintenance & Monitoring

### Post-Load Validation
```sql
-- Verify row count
SELECT COUNT(*) FROM marts.dim_customers;

-- Check for unexpected NULLs
SELECT * FROM marts.dim_customers WHERE customer_id IS NULL;

-- Validate segment distribution
SELECT customer_segment, COUNT(*) FROM marts.dim_customers GROUP BY 1;

-- Monitor churn risk distribution
SELECT churn_risk, COUNT(*) FROM marts.dim_customers GROUP BY 1;
```

### Common Issues & Remediation
| Issue | Symptom | Fix |
|-------|---------|-----|
| Duplicate customers in output | Row count > expected; metrics duplicated | Check `stg_raw_customers` for duplicates; add `DISTINCT ON (customer_id)` |
| All customers marked "Never Purchased" | `total_orders = 0` for all rows | Verify `fct_orders` is populated; check join logic |
| RFM scores all = 1 | All customers in lowest tier | Check for NULL values in `fct_orders`; validate `NTILE()` logic |
| Slow query performance | Load time > 30 minutes | Check Redshift cluster resources; consider incremental refresh |
| Stale data in BI tools | Metrics don't match reality | Verify `_loaded_at` timestamp; check if BI tool cache is stale |

---

## Related Documentation
- **marts.fct_orders:** Order fact table; source of transactional data
- **staging.stg_raw_customers:** Customer staging table; source of master data
- **RFM Segmentation Framework:** [Link to business rules doc]
- **Churn Risk Thresholds:** [Link to retention strategy doc]
- **Redshift Best Practices:** [Link to internal wiki]