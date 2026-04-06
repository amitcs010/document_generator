# marts/dim_customers.sql

## Component Overview
- **Layer:** Marts
- **Type:** Table (materialized dimension)
- **Schedule:** Not specified in code; infer from dbt/orchestration config
- **Owner:** Not specified in code; infer from team documentation

---

## Purpose

This component builds a comprehensive **customer master dimension** that enriches raw customer attributes with behavioral metrics, RFM segmentation, and churn risk classification. It serves as the single source of truth for BI tools, analysts, and marketing teams to understand customer value, engagement patterns, and lifetime economics. The table enables downstream reporting on customer segments, retention analysis, and personalization use cases.

---

## Inputs

| Source | Purpose | Dependency |
|--------|---------|-----------|
| **staging.stg_raw_customers** | Provides core customer attributes (identity, contact, registration, loyalty tier, marketing preferences). This is the authoritative customer master. | Must be populated before this mart runs. |
| **marts.fct_orders** | Provides transactional order history (revenue, margin, refunds, channels, payment methods, order dates). Used to calculate behavioral metrics and RFM scores. | Must be fully populated; incomplete order data will skew RFM and lifetime value calculations. |

---

## Outputs

| Target | Contents | Downstream Consumers |
|--------|----------|---------------------|
| **marts.dim_customers** | Denormalized customer dimension with 30+ columns including identity, order history, RFM scores, segmentation, and churn risk. Distributed by `customer_id` for efficient joins. | BI dashboards (Tableau, Looker), marketing automation platforms, customer analytics reports, retention models, cohort analysis tools. |

---

## Key Business Logic

### 1. **Customer Order Aggregation** (`customer_orders` CTE)
Aggregates all orders per customer to compute:
- **Lifetime metrics:** total orders, lifetime revenue, lifetime margin, total units purchased
- **Temporal metrics:** first/last order dates, active months (distinct order months)
- **Quality metrics:** refund count, average order value
- **Preference metrics:** most common order channel and payment method (using `MODE()`)

**Why:** Enables single-row-per-customer design and provides the foundation for RFM scoring and segmentation.

**Edge case:** Customers with no orders will have NULL values in this CTE; these are handled downstream with `NVL()` defaults.

---

### 2. **RFM Scoring** (`rfm` CTE)
Calculates three independent dimensions:
- **Recency (R):** Days since last order, scored 1–5 (5 = most recent)
- **Frequency (F):** Total order count, scored 1–5 (5 = most frequent)
- **Monetary (M):** Lifetime revenue, scored 1–5 (5 = highest spender)

Each score is computed using `NTILE(5)` window function, which divides customers into quintiles. Lower recency values (fewer days since last order) receive higher scores.

**Why:** RFM is a standard segmentation framework that identifies high-value, engaged customers and at-risk segments without requiring complex ML models.

**Assumption:** Recency scoring assumes that "more recent = better"; this may not hold for seasonal businesses or subscription models.

---

### 3. **Customer Segmentation Logic**
Hierarchical business rules classify customers into 8 segments:

| Segment | Criteria | Business Meaning |
|---------|----------|------------------|
| **Never Purchased** | `total_orders IS NULL` | Registered but inactive; acquisition funnel drop-off. |
| **Champions** | R ≥ 4, F ≥ 4, M ≥ 4 | Top-tier customers; recent, frequent, high-value. Target for VIP programs. |
| **Loyal Customers** | R ≥ 4, F ≥ 3 | Repeat buyers with recent activity; core revenue base. |
| **New Customers** | R ≥ 4, F ≤ 2 | Recent first/second purchases; high conversion potential. |
| **Potential Loyalists** | R ≥ 3, F ≥ 3 | Moderate recency and frequency; nurture for loyalty. |
| **At Risk** | R ≤ 2, F ≥ 3 | Previously frequent but inactive; re-engagement opportunity. |
| **Cant Lose Them** | R ≤ 2, F ≤ 2, M ≥ 3 | High-value but dormant; critical retention target. |
| **Hibernating** | R ≤ 2, F ≤ 2 | Low engagement and value; low priority. |
| **Other** | Unmatched | Catch-all for edge cases. |

**Why:** Enables targeted marketing campaigns, resource allocation, and risk mitigation strategies.

**Risk:** Rules are hardcoded; changes require SQL modification and redeployment. Consider externalizing thresholds to a config table.

---

### 4. **Churn Risk Classification**
Assigns risk levels based on days since last order:

| Risk Level | Threshold | Action |
|------------|-----------|--------|
| **no_purchase** | Never ordered | Acquisition focus. |
| **high_risk** | > 180 days | Urgent win-back campaigns. |
| **medium_risk** | 91–180 days | Engagement campaigns. |
| **low_risk** | 31–90 days | Retention messaging. |
| **active** | ≤ 30 days | Upsell/cross-sell focus. |

**Why:** Provides a simple, actionable metric for prioritizing retention efforts.

**Assumption:** 180/90/30-day thresholds are business-defined; they should be validated against actual churn patterns and may vary by product category or geography.

---

### 5. **Refund Rate Calculation**
```
refund_rate_pct = (refund_count / total_orders) * 100
```

**Why:** Identifies problematic customers (high refund rates) or product quality issues.

**Edge case:** Customers with zero orders receive 0% refund rate (not NULL), which is semantically correct.

---

### 6. **Data Enrichment & Masking**
Joins `stg_raw_customers` attributes (email hash, name masked, postal code masked, loyalty tier, marketing opt-in) with behavioral metrics. Masking indicates PII compliance measures are in place.

**Why:** Provides context for segmentation while protecting customer privacy.

---

## Column Descriptions

| Column | Type | Description | Example |
|--------|------|-------------|---------|
| **customer_id** | INT | Unique customer identifier; primary key. | `12345` |
| **email_hash** | VARCHAR | SHA-256 hash of email for privacy compliance. | `a1b2c3d4...` |
| **email_domain** | VARCHAR | Domain extracted from email for cohort analysis. | `gmail.com` |
| **first_name_masked** | VARCHAR | First name with PII masking applied. | `J***` |
| **country** | VARCHAR | Customer's country of residence. | `US`, `CA`, `GB` |
| **registration_date** | DATE | Account creation date. | `2023-01-15` |
| **loyalty_tier** | VARCHAR | Customer's loyalty program tier. | `gold`, `silver`, `bronze`, `none` |
| **total_orders** | INT | Lifetime count of orders (0 if never purchased). | `42` |
| **lifetime_revenue** | DECIMAL(18,2) | Sum of gross revenue across all orders. | `5234.99` |
| **lifetime_margin** | DECIMAL(18,2) | Sum of profit margin across all orders. | `1523.45` |
| **first_order_date** | DATE | Date of first purchase (NULL if never purchased). | `2023-02-01` |
| **last_order_date** | DATE | Date of most recent purchase (NULL if never purchased). | `2024-01-20` |
| **avg_order_value** | DECIMAL(18,2) | Mean revenue per order. | `124.64` |
| **active_months** | INT | Count of distinct months with at least one order. | `8` |
| **refund_count** | INT | Total number of refunded orders. | `2` |
| **total_units_purchased** | INT | Sum of units across all orders. | `156` |
| **preferred_channel** | VARCHAR | Most frequently used order channel (mode). | `web`, `mobile`, `phone`, `in_store` |
| **preferred_payment** | VARCHAR | Most frequently used payment method (mode). | `credit_card`, `paypal`, `apple_pay` |
| **recency_score** | INT | RFM recency quintile (1–5; 5 = most recent). | `5` |
| **frequency_score** | INT | RFM frequency quintile (1–5; 5 = most frequent). | `4` |
| **monetary_score** | INT | RFM monetary quintile (1–5; 5 = highest value). | `5` |
| **rfm_total** | INT | Sum of R, F, M scores (3–15). | `14` |
| **customer_segment** | VARCHAR | Business segment classification. | `Champions`, `At Risk`, `Hibernating` |
| **churn_risk** | VARCHAR | Risk level based on recency. | `active`, `low_risk`, `medium_risk`, `high_risk`, `no_purchase` |
| **refund_rate_pct** | DECIMAL(5,2) | Percentage of orders that were refunded. | `4.76` |
| **_loaded_at** | TIMESTAMP | Timestamp when row was inserted/updated. | `2024-01-21 02:15:00` |

---

## Data Quality & Edge Cases

### Null Handling
- **Never-purchased customers:** `customer_orders` CTE returns NULL for all aggregates. These are coalesced to 0 (orders, revenue, margin, units, refund count) or `'none'` (channel, payment) using `NVL()`.
- **RFM scores for never-purchased:** Coalesced to 1 (lowest quintile), which is semantically correct.
- **Churn risk for never-purchased:** Explicitly set to `'no_purchase'` before RFM logic, preventing NULL propagation.

### Deduplication Strategy
- **No explicit deduplication:** Assumes `stg_raw_customers` is already deduplicated by `customer_id` (primary key).
- **Risk:** If upstream contains duplicate customer records, this query will produce duplicate rows in the output. Recommend adding a `DISTINCT` or validating upstream uniqueness.

### Key Assumptions
1. **Customer ID uniqueness:** `stg_raw_customers.customer_id` is unique and stable.
2. **Order date completeness:** All orders in `marts.fct_orders` have valid `order_date` values; NULL dates will break recency calculations.
3. **RFM thresholds are static:** Quintile boundaries change as customer behavior evolves; consider recalibrating quarterly.
4. **Segmentation rules are exhaustive:** The `CASE` statement covers all meaningful combinations; unmapped customers fall to `'Other'`.
5. **Churn thresholds are universal:** 180/90/30-day windows apply equally to all customer cohorts; seasonal or product-specific adjustments are not made.
6. **Refund data is accurate:** `is_refunded` flag in `fct_orders` is reliable; misclassified refunds will skew refund rates.

### Potential Data Quality Issues
- **Missing order dates:** Will cause `DATEDIFF()` to return NULL, breaking recency scoring.
- **Future order dates:** If `order_date > GETDATE()`, recency becomes negative; consider adding validation.
- **Duplicate orders:** If `fct_orders` contains duplicate transactions, aggregates (total_orders, lifetime_revenue) will be inflated.
- **Inconsistent customer IDs:** If `stg_raw_customers` and `fct_orders` use different ID schemes, joins will fail silently, producing NULL metrics.
- **Stale customer master:** If `stg_raw_customers` is not refreshed regularly, new customers may be missing.

---

## Performance Notes

### Join Strategy
- **LEFT JOIN from `stg_raw_customers`:** Ensures all registered customers appear in output, even if they have no orders. This is correct for a dimension table.
- **LEFT JOIN from CTEs:** Handles never-purchased customers gracefully with NULL coalescing.
- **Join key:** `customer_id` is used consistently; ensure it's indexed in both source tables.

### Distribution & Sorting
```sql
DISTKEY(customer_id)
SORTKEY(customer_id)
```
- **DISTKEY:** Distributes rows across Redshift nodes by `customer_id`. This is optimal for joins on `customer_id` in downstream queries.
- **SORTKEY:** Sorts rows within each node by `customer_id`. Improves query performance for range scans and joins.
- **Implication:** Queries filtering by `customer_id` will be fast; queries filtering by `customer_segment` or `churn_risk` may require full table scans.

### Expensive Operations
1. **`MODE()` window function:** Computes the most common value for `order_channel` and `payment_method`. This is O(n log n) per customer and may be slow for customers with many orders. Consider pre-aggregating in `fct_orders` if performance degrades.
2. **`NTILE(5)` window functions:** Requires sorting all customers by recency, frequency, and monetary value. This is O(n log n) globally but is unavoidable for RFM scoring.
3. **`APPROXIMATE COUNT(DISTINCT order_month)`:** Uses HyperLogLog approximation for speed; exact count would require a subquery or GROUP BY.

### Table Size Estimate
- **Rows:** Equal to unique customers in `stg_raw_customers` (typically 100K–10M).
- **Columns:** 30+, mostly numeric or short strings.
- **Estimated size:** 100K customers × 30 columns × ~50 bytes/column ≈ 150 MB (uncompressed). Redshift compression typically reduces this by 70–80%.

### Refresh Strategy
- **Full refresh:** `DROP TABLE IF EXISTS` followed by `CREATE TABLE AS` is a full rebuild. This is safe but locks the table during creation.
- **Alternative:** Consider `CREATE TABLE ... AS` with a temporary name, then `ALTER TABLE ... RENAME` for zero-downtime updates (if supported by orchestration).

---

## Dependencies

### Upstream (Must Run Before This Component)
1. **staging.stg_raw_customers**
   - Loads raw customer data from source systems (CRM, registration database).
   - Must include: `customer_id`, `email_hash`, `first_name_masked`, `country`, `registration_date`, `loyalty_tier`, `marketing_opt_in`, etc.
   - Frequency: Daily or on-demand.

2. **marts.fct_orders**
   - Aggregates transactional order data with revenue, margin, refunds, channels, payment methods.
   - Must include: `customer_id`, `order_date`, `order_month`, `gross_revenue`, `total_margin`, `is_refunded`, `order_channel`, `payment_method`, `total_units`.
   - Frequency: Daily (incremental or full refresh).
   - **Critical:** Must be fully populated before RFM scoring; partial data will produce incorrect quintiles.

### Downstream (Depends on This Component)
1. **BI Dashboards & Reports**
   - Tableau, Looker, Power BI dashboards query `dim_customers` for customer segmentation, RFM analysis, churn risk reporting.
   - Queries typically filter by `customer_segment`, `churn_risk`, `loyalty_tier`.

2. **Marketing Automation Platforms**
   - Segment exports (e.g., to Salesforce, HubSpot) use `customer_segment` and `churn_risk` to trigger campaigns.
   - Frequency: Daily or real-time syncs.

3. **Retention & Churn Models**
   - Data scientists use `dim_customers` as a feature source for predictive churn models.
   - Columns used: `recency_score`, `frequency_score`, `monetary_score`, `refund_rate_pct`, `active_months`.

4. **Customer Analytics Reports**
   - Analysts query for cohort analysis, lifetime value trends, segment performance.
   - Typical queries: "How many customers are in each segment?" "What's the average LTV by loyalty tier?"

### External Dependencies
- **GETDATE():** Uses Redshift system clock for current timestamp. Assumes server time is accurate and in UTC.
- **Permissions:** Grants `SELECT` to `analytics_readers` and `bi_team` groups; assumes these groups exist in Redshift.
- **ANALYZE command:** Triggers table statistics update; requires sufficient disk space and may lock the table briefly.

### Circular Dependencies
- **None detected.** This is a leaf node in the DAG; it does not feed back into `fct_orders` or `stg_raw_customers`.

---

## Maintenance & Operational Notes

### Monitoring
- **Row count:** Track daily row count to detect missing customers or deduplication failures.
- **NULL rates:** Monitor NULL percentages in `first_order_date`, `last_order_date`, `preferred_channel` to detect upstream data quality issues.
- **Segment distribution:** Alert if any segment drops to 0% or exceeds 80% (indicates skewed segmentation).
- **Refresh duration:** Track query execution time; alert if it exceeds SLA (e.g., 30 minutes).

### Troubleshooting
- **Missing customers:** Check if `stg_raw_customers` is populated; verify `customer_id` join key consistency.
- **Incorrect RFM scores:** Verify `fct_orders.order_date` is not NULL; check for future-dated orders.
- **High refund rates:** Validate `is_refunded` flag in `fct_orders`; check for duplicate refund records.
- **Slow queries:** Check Redshift query plan; consider adding indexes on `customer_segment`, `churn_risk` if filtering is common.

### Future Enhancements
1. **Externalizing segmentation rules:** Move hardcoded thresholds to a config table for easier updates.
2. **Product-level RFM:** Calculate separate RFM scores per product category.
3. **Predictive churn:** Replace rule-based churn risk with ML model scores.
4. **Incremental refresh:** Implement upsert logic to update only changed customers instead of full rebuild.
5. **Customer lifetime value (CLV):** Add predictive CLV column using historical margin trends.