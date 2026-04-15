# marts/dim_customers.sql

## Component Overview
- **Layer:** Marts
- **Type:** Table (materialized dimension)
- **Schedule:** Not specified in code; recommend daily refresh post-`fct_orders` load
- **Owner:** Not specified in code; recommend Analytics Engineering team

---

## Purpose

This component builds a comprehensive customer dimension table that enriches raw customer attributes with behavioral metrics, RFM segmentation, and churn risk scoring. It serves as the single source of truth for customer analytics, enabling BI tools and analysts to perform customer lifetime value analysis, segmentation-based reporting, and retention campaign targeting without requiring complex joins to transactional data.

---

## Inputs

### `staging.stg_raw_customers`
Provides core customer identity and profile data: email (hashed for privacy), location, registration metadata, loyalty tier, and marketing preferences. This component needs it to establish the customer dimension's grain and to include demographic/preference attributes required by downstream BI consumers.

### `marts.fct_orders`
Provides the complete order transaction history including order dates, revenue, margins, refund flags, channels, and payment methods. This component needs it to calculate behavioral metrics (recency, frequency, monetary value) and derive customer segments based on purchase patterns.

---

## Outputs

### `marts.dim_customers`
A denormalized customer dimension table containing:
- **Identity & Profile:** customer_id, email, name, location, registration date
- **Behavioral Metrics:** total orders, lifetime revenue/margin, average order value, active months, refund rate
- **RFM Scores:** recency, frequency, monetary quintile scores (1–5) and composite RFM total
- **Segmentation:** customer_segment (Champions, Loyal Customers, At Risk, etc.) and churn_risk classification
- **Metadata:** load timestamp for lineage tracking

**Consumed by:** BI dashboards (Tableau, Looker), customer analytics reports, retention/marketing campaign tools, data scientists building predictive models.

---

## Key Business Logic

### 1. **Customer Order Aggregation** (`customer_orders` CTE)
Aggregates all orders per customer to compute:
- **Frequency metrics:** `total_orders`, `active_months` (distinct order months)
- **Monetary metrics:** `lifetime_revenue`, `lifetime_margin`, `avg_order_value`
- **Recency anchors:** `first_order_date`, `last_order_date` (used downstream for churn calculation)
- **Quality indicators:** `refund_count`, `total_units_purchased`
- **Preference modes:** `preferred_channel`, `preferred_payment` (most common values per customer)

**Why:** Reduces transactional grain to customer grain, enabling efficient dimension lookups and avoiding repeated aggregation in downstream queries.

### 2. **RFM Scoring** (`rfm` CTE)
Calculates three independent quintile scores (1–5, where 5 = best):
- **Recency (`r_score`):** Days since last order, ranked ascending (lower days = higher score). Identifies recently active customers.
- **Frequency (`f_score`):** Total order count, ranked ascending. Identifies repeat purchasers.
- **Monetary (`m_score`):** Lifetime revenue, ranked ascending. Identifies high-value customers.

**Why:** RFM is a proven segmentation framework. Quintile scoring (NTILE) ensures balanced distribution across tiers and enables consistent business rule application.

### 3. **Customer Segmentation Logic**
Hierarchical business rules map RFM scores to actionable segments:

| Segment | Rule | Business Implication |
|---------|------|----------------------|
| **Champions** | r ≥4, f ≥4, m ≥4 | Highest-value, most recent, frequent buyers. Retention focus. |
| **Loyal Customers** | r ≥4, f ≥3 | Recent and repeat buyers. Upsell/cross-sell targets. |
| **New Customers** | r ≥4, f ≤2 | Recent but low frequency. Nurture for repeat purchase. |
| **Potential Loyalists** | r ≥3, f ≥3 | Moderate recency/frequency. Growth opportunity. |
| **At Risk** | r ≤2, f ≥3 | Previously frequent but inactive. Win-back campaigns. |
| **Can't Lose Them** | r ≤2, f ≤2, m ≥3 | High-value but dormant. Critical retention focus. |
| **Hibernating** | r ≤2, f ≤2, m <3 | Low engagement and value. Low priority. |
| **Never Purchased** | No orders | Registered but inactive. Onboarding/activation focus. |

**Why:** Enables targeted marketing and retention strategies without requiring separate segmentation logic in downstream tools.

### 4. **Churn Risk Classification**
Time-based risk buckets based on days since last order:
- **`no_purchase`:** Never ordered (registration-only users)
- **`high_risk`:** >180 days inactive (6+ months)
- **`medium_risk`:** 91–180 days inactive (3–6 months)
- **`low_risk`:** 31–90 days inactive (1–3 months)
- **`active`:** ≤30 days since last order

**Why:** Provides a simple, interpretable churn proxy for campaign targeting and risk-based analytics without requiring predictive modeling.

### 5. **Refund Rate Calculation**
```
refund_rate_pct = (refund_count / total_orders) * 100
```
Handles division-by-zero with conditional logic (returns 0 if no orders).

**Why:** Identifies problematic customers (high refund rates may indicate fraud, dissatisfaction, or product misfit) and quality issues.

---

## Column Descriptions

| Column | Type | Description | Example Values |
|--------|------|-------------|-----------------|
| **customer_id** | INT | Unique customer identifier. Primary key. | 12345, 67890 |
| **email_hash** | VARCHAR | SHA-256 hash of customer email for privacy compliance. | `a1b2c3d4...` |
| **email_domain** | VARCHAR | Extracted domain for cohort analysis (e.g., corporate vs. consumer). | `gmail.com`, `company.com` |
| **first_name_masked** | VARCHAR | First name with PII masking applied (e.g., first letter + asterisks). | `J***`, `M***` |
| **country** | VARCHAR | Customer's billing country. | `US`, `CA`, `GB` |
| **registration_date** | DATE | Account creation date. | `2023-01-15` |
| **total_orders** | INT | Lifetime count of orders (including refunded). | 0, 5, 42 |
| **lifetime_revenue** | DECIMAL(18,2) | Sum of gross revenue across all orders. | 0.00, 1250.50, 15000.00 |
| **lifetime_margin** | DECIMAL(18,2) | Sum of profit margin across all orders. | 0.00, 350.25, 4500.00 |
| **last_order_date** | DATE | Most recent order date. NULL if never purchased. | `2024-01-10`, NULL |
| **avg_order_value** | DECIMAL(18,2) | Mean revenue per order. | 0.00, 125.75, 500.00 |
| **recency_score** | INT | RFM quintile (1–5) based on days since last order. 5 = most recent. | 1, 3, 5 |
| **frequency_score** | INT | RFM quintile (1–5) based on total orders. 5 = most frequent. | 1, 2, 5 |
| **monetary_score** | INT | RFM quintile (1–5) based on lifetime revenue. 5 = highest value. | 1, 4, 5 |
| **rfm_total** | INT | Sum of recency + frequency + monetary scores. Range: 3–15. | 3, 9, 15 |
| **customer_segment** | VARCHAR | Business segment derived from RFM rules. | `Champions`, `At Risk`, `Hibernating`, `Never Purchased` |
| **churn_risk** | VARCHAR | Risk classification based on inactivity duration. | `active`, `low_risk`, `high_risk`, `no_purchase` |
| **refund_rate_pct** | DECIMAL(5,2) | Percentage of orders that were refunded. | 0.00, 5.50, 25.00 |
| **_loaded_at** | TIMESTAMP | ETL load timestamp for data freshness tracking. | `2024-01-15 02:30:00` |

---

## Data Quality & Edge Cases

### Null Handling
- **`NVL()` wrapping:** All aggregated metrics from `customer_orders` are wrapped in `NVL()` to handle customers with no orders (LEFT JOIN result). Defaults: 0 for counts/sums, 'none' for modes, 1 for RFM scores.
- **Rationale:** Ensures all customers in `stg_raw_customers` appear in output, even if they've never purchased. Prevents NULL propagation in downstream calculations.

### Deduplication Strategy
- **Grain:** Customer dimension is at `customer_id` grain (one row per customer).
- **No explicit deduplication:** Assumes `stg_raw_customers` and `marts.fct_orders` are already deduplicated at their respective grains.
- **Risk:** If `stg_raw_customers` contains duplicate customer_id rows, the LEFT JOIN will produce duplicate output rows. Recommend adding a `ROW_NUMBER()` deduplication step in `stg_raw_customers` if this is a known issue.

### Assumptions About Upstream Data
1. **`customer_id` uniqueness:** `stg_raw_customers.customer_id` is unique; `marts.fct_orders.customer_id` references valid customers.
2. **Order dates are valid:** `order_date` is not NULL and is a valid date (no future dates).
3. **Revenue is non-negative:** `gross_revenue`, `total_margin` are >= 0 (no negative values representing adjustments).
4. **Refund flag is boolean:** `is_refunded` is 0/1 or TRUE/FALSE.
5. **MODE() aggregation:** Assumes `order_channel` and `payment_method` have meaningful modes (not all NULL or all unique).

### Potential Failure Points
- **MODE() with all NULLs:** If a customer has no orders with a channel/payment method, MODE() may return NULL or error. Mitigated by `NVL()` default to 'none'.
- **GETDATE() timezone:** `GETDATE()` is server-local time; if servers span timezones, recency calculations may drift. Recommend standardizing to UTC.
- **Refund rate division:** Handled with conditional logic, but if `total_orders` is 0 and `refund_count` is non-zero (data inconsistency), result is 0 (may mask issues).
- **RFM score ties:** NTILE() breaks ties arbitrarily; customers with identical RFM values may be assigned different quintiles. Not a functional issue but may cause slight inconsistency in segment boundaries.

---

## Performance Notes

### Join Strategy
- **LEFT JOIN from `stg_raw_customers`:** Ensures all customers are retained, even non-purchasers. Requires full scan of both tables.
- **Two LEFT JOINs:** First to `customer_orders`, second to `rfm`. Both CTEs are derived from `marts.fct_orders`, so they're computed once and joined twice. Efficient if `fct_orders` is indexed on `customer_id`.

### Expensive Operations
- **APPROXIMATE COUNT(DISTINCT order_month):** Uses Redshift's approximate distinct count for performance (exact count would require full scan). Acceptable for "active months" metric where ±5% error is tolerable.
- **MODE() WITHIN GROUP:** Requires sorting per customer; O(n log n) per group. Can be slow if many unique channels/payment methods per customer. Consider replacing with `FIRST_VALUE()` if performance degrades.
- **NTILE() window functions:** Requires full sort of `customer_orders` table three times (once per RFM dimension). Expensive on large customer bases (100M+ rows). Mitigated by Redshift's distributed execution.

### Partitioning & Distribution
- **DISTKEY(customer_id):** Distributes rows across nodes by customer_id. Ensures all orders for a customer co-locate, optimizing the `customer_orders` aggregation join.
- **SORTKEY(customer_id):** Sorts rows within each node by customer_id. Enables efficient range scans if downstream queries filter by customer_id (common in BI tools).
- **Rationale:** Optimizes for the expected access pattern: BI tools querying individual customers or customer segments.

### Table Size Estimate
- Assuming 10M customers, ~50 columns, ~100 bytes/row → ~500 GB uncompressed.
- Redshift compression typically achieves 3–5x, so ~100–150 GB on disk.
- Full table scan: ~10–30 seconds on modern Redshift cluster.

### ANALYZE Statement
- `ANALYZE marts.dim_customers;` updates table statistics for query planner. Recommended after every full refresh to ensure optimal execution plans.

---

## Dependencies

### Upstream (Must Run Before This Component)
1. **`staging.stg_raw_customers`** — Raw customer data must be loaded and deduplicated.
2. **`marts.fct_orders`** — Order fact table must be fully loaded with all historical transactions. This is the critical path; any delays in order processing delay customer dimension refresh.

### Downstream (Components Depending on This Output)
1. **BI Dashboards** — Tableau, Looker, Power BI dashboards join `dim_customers` to fact tables for customer analytics, segmentation reports, and KPI tracking.
2. **`marts.fct_customer_metrics`** (if exists) — Likely joins this dimension for enriched customer-level metrics.
3. **Marketing Automation Tools** — Export customer segments and churn risk to Salesforce, HubSpot, or email platforms for campaign targeting.
4. **Data Science Models** — Churn prediction, LTV forecasting, and propensity models use RFM scores and customer segments as features.
5. **Customer 360 Views** — Data apps and customer service tools query this table for unified customer profiles.

### External Dependencies
- **`GROUP analytics_readers`, `GROUP bi_team`** — Redshift IAM groups for access control. Assumes these groups exist and are managed by infrastructure team.
- **`GETDATE()` function** — Redshift system function; assumes server time is synchronized and in expected timezone.

---

## Maintenance & Monitoring Recommendations

### Refresh Cadence
- **Recommended:** Daily, post-`fct_orders` load (typically 2–4 AM UTC).
- **Rationale:** RFM scores and churn risk are time-sensitive; stale data (>24 hours) degrades segmentation accuracy.

### Data Quality Checks
- Monitor `refund_rate_pct` distribution; spikes may indicate fraud or product issues.
- Alert if `customer_segment` distribution shifts >10% month-over-month (may indicate data quality issue or business change).
- Validate `rfm_total` range (should be 3–15); values outside this range indicate scoring logic error.

### Query Performance Monitoring
- Track query execution time; if >60 seconds, investigate `fct_orders` size growth or missing indexes.
- Monitor Redshift node CPU/memory during refresh; if >80%, consider cluster resize.