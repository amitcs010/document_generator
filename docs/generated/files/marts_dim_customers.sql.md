# marts/dim_customers.sql

## Component Overview
- **Layer:** Marts
- **Type:** Table (materialized dimension)
- **Schedule:** Not specified in code; infer from orchestration layer (typically daily)
- **Owner:** Not specified in code; infer from analytics/BI team ownership

---

## Purpose

This component builds a comprehensive **customer dimension table** that enriches raw customer attributes with behavioral metrics, RFM (Recency, Frequency, Monetary) scoring, and predictive segmentation. It serves as the single source of truth for customer analytics, enabling BI tools and analysts to slice orders, revenue, and engagement by customer segment, churn risk, and lifetime value without recalculating metrics on every query.

---

## Inputs

| Source | Purpose | Why Needed |
|--------|---------|-----------|
| **marts.fct_orders** | Order-level transactions with revenue, margin, refunds, channels, and payment methods | Aggregates customer purchase history, calculates lifetime value, frequency, and preferred behaviors |
| **staging.stg_raw_customers** | Customer master data: identity (hashed), location, registration, login, loyalty tier, marketing preferences | Provides stable customer attributes and compliance-masked PII; left join ensures all registered customers appear even if they've never purchased |

---

## Outputs

| Target | Contents | Downstream Consumers |
|--------|----------|---------------------|
| **marts.dim_customers** | 1 row per customer with 40+ columns spanning identity, order history, RFM scores, segmentation, and churn risk | BI dashboards (Tableau, Looker), analyst ad-hoc queries, ML models for churn prediction, marketing automation platforms, customer success teams |

---

## Key Business Logic

### 1. **Customer Order Aggregation** (CTE: `customer_orders`)
Rolls up all orders per customer to compute:
- **Lifetime metrics:** total orders, lifetime revenue, lifetime margin, total units purchased
- **Temporal metrics:** first/last order dates, active months (distinct order months)
- **Quality metrics:** refund count, average order value
- **Behavioral metrics:** preferred channel and payment method (mode = most frequent)

**Why:** Enables single-row customer view without denormalization; supports segmentation and RFM scoring downstream.

**Edge case:** `APPROXIMATE COUNT(DISTINCT order_month)` trades precision for speed on large datasets; use exact count if monthly granularity is critical for compliance.

---

### 2. **RFM Scoring** (CTE: `rfm`)
Calculates three independent dimensions:
- **Recency (R):** Days since last order, scored 1–5 (5 = most recent)
- **Frequency (F):** Total order count, scored 1–5 (5 = most frequent)
- **Monetary (M):** Lifetime revenue, scored 1–5 (5 = highest spender)

Uses `NTILE(5)` window function to rank customers into quintiles independently per dimension.

**Why:** RFM is a proven segmentation framework; quintile scoring normalizes skewed distributions (e.g., revenue is often right-skewed) and enables consistent business rules.

**Assumption:** Assumes order dates are reliable; if clock skew exists in `fct_orders.order_date`, recency scores will be inaccurate.

---

### 3. **Customer Segmentation** (CASE statement)
Maps RFM scores to 8 business-meaningful segments:

| Segment | Criteria | Business Action |
|---------|----------|-----------------|
| **Champions** | R≥4, F≥4, M≥4 | VIP retention, upsell, referral programs |
| **Loyal Customers** | R≥4, F≥3 | Cross-sell, loyalty rewards |
| **New Customers** | R≥4, F≤2 | Onboarding, education, repeat incentives |
| **Potential Loyalists** | R≥3, F≥3 | Engagement campaigns, personalization |
| **At Risk** | R≤2, F≥3 | Win-back campaigns, discounts |
| **Can't Lose Them** | R≤2, F≤2, M≥3 | High-touch outreach, VIP retention |
| **Hibernating** | R≤2, F≤2, M<3 | Re-engagement, survey, sunset |
| **Never Purchased** | No orders | Nurture, onboarding, or remove from list |

**Why:** Translates statistical scores into actionable marketing personas; enables targeted campaigns.

**Risk:** Segment boundaries are hardcoded; if business strategy changes (e.g., "loyal" threshold shifts from F≥3 to F≥4), SQL must be updated and table rebuilt.

---

### 4. **Churn Risk Classification**
Assigns risk level based on days since last order:

| Risk Level | Days Since Last Order | Interpretation |
|------------|----------------------|-----------------|
| **no_purchase** | Never ordered | Prospect, not customer |
| **active** | ≤30 days | Engaged, low churn risk |
| **low_risk** | 31–90 days | Normal purchase cycle, monitor |
| **medium_risk** | 91–180 days | Declining engagement, intervention needed |
| **high_risk** | >180 days | Likely churned, urgent win-back |

**Why:** Provides simple, time-based churn proxy; enables prioritization of retention efforts.

**Assumption:** Assumes 180-day threshold is appropriate for the business; varies by industry (e.g., SaaS vs. e-commerce). Should be parameterized or documented as a business rule.

---

### 5. **Refund Rate Calculation**
```
refund_count / total_orders * 100
```
Flags customers with high return rates (potential fraud, product quality issues, or fit problems).

**Why:** Identifies problematic customers or product categories; informs quality and fraud teams.

**Edge case:** Customers with 0 orders return refund_rate_pct = 0 (via `NVL`); this is correct but could be misinterpreted as "no refunds" vs. "no data."

---

### 6. **Null Handling Strategy**
Extensive use of `NVL()` ensures:
- Customers with no orders still appear (left join from `stg_raw_customers`)
- Metrics default to 0 (not NULL) for easier downstream aggregation
- Categorical fields default to 'none' (not NULL) to avoid GROUP BY issues

**Why:** Prevents NULL propagation in BI tools; simplifies SUM/COUNT operations.

**Trade-off:** Masks missing data; analysts must check `total_orders = 0` to identify never-purchased customers rather than relying on NULL.

---

## Column Descriptions

| Column | Type | Description | Example |
|--------|------|-------------|---------|
| **customer_id** | INT | Unique customer identifier; distribution key | 12345 |
| **email_hash** | VARCHAR | SHA-256 hash of email for privacy compliance | `a1b2c3d4...` |
| **email_domain** | VARCHAR | Domain extracted from email for cohort analysis | `gmail.com` |
| **first_name_masked** | VARCHAR | First name with PII masking (e.g., first letter + asterisks) | `J***` |
| **country** | VARCHAR | Customer billing country; enables geo-segmentation | `US`, `CA`, `GB` |
| **registration_date** | DATE | Account creation date | `2023-01-15` |
| **total_orders** | INT | Lifetime order count; key RFM dimension | 0–1000+ |
| **lifetime_revenue** | DECIMAL(18,2) | Total gross revenue from all orders | `1,250.50` |
| **lifetime_margin** | DECIMAL(18,2) | Total profit margin across all orders | `312.75` |
| **first_order_date** | DATE | Date of first purchase; identifies cohort | `2023-02-01` |
| **last_order_date** | DATE | Date of most recent purchase; basis for recency | `2024-01-20` |
| **avg_order_value** | DECIMAL(18,2) | Mean revenue per order; proxy for customer value | `125.05` |
| **active_months** | INT | Count of distinct months with orders; engagement proxy | 1–60 |
| **preferred_channel** | VARCHAR | Most frequent order channel (mode); enables channel strategy | `web`, `mobile`, `phone` |
| **recency_score** | INT | RFM recency quintile (1=oldest, 5=most recent) | 1–5 |
| **frequency_score** | INT | RFM frequency quintile (1=least frequent, 5=most frequent) | 1–5 |
| **monetary_score** | INT | RFM monetary quintile (1=lowest spender, 5=highest) | 1–5 |
| **rfm_total** | INT | Sum of three RFM scores; simple overall value metric | 3–15 |
| **customer_segment** | VARCHAR | Business segment derived from RFM rules | `Champions`, `At Risk`, `Hibernating` |
| **churn_risk** | VARCHAR | Predicted churn likelihood based on recency | `active`, `high_risk`, `no_purchase` |
| **refund_rate_pct** | DECIMAL(5,2) | Percentage of orders that were refunded | 0.00–100.00 |
| **_loaded_at** | TIMESTAMP | Table load timestamp; enables incremental refresh logic | `2024-01-21 02:15:00` |

---

## Data Quality & Edge Cases

### Null Handling
- **Never-purchased customers:** Appear in output with `total_orders = 0`, `lifetime_revenue = 0`, `customer_segment = 'Never Purchased'`. This is correct and intentional (left join from `stg_raw_customers`).
- **Missing RFM scores:** Customers with no orders have `r_score = 1`, `f_score = 1`, `m_score = 1` (via `NVL`). This is a design choice; consider whether "never purchased" should be scored at all or flagged separately.
- **Missing preferred channel/payment:** Defaults to `'none'` if customer has no orders; this is correct.

### Deduplication
- **No explicit deduplication:** Assumes `stg_raw_customers` has 1 row per `customer_id` (enforced upstream). If duplicates exist, the LEFT JOIN will create multiple rows per customer.
- **Recommendation:** Add a `SELECT DISTINCT ON (customer_id)` or `ROW_NUMBER()` filter if upstream data quality is uncertain.

### Key Assumptions
1. **Order dates are accurate:** Recency calculation depends on `fct_orders.order_date` being reliable; clock skew or backdated orders will corrupt RFM scores.
2. **Customer IDs are stable:** No customer ID reuse or merging; if customers are merged post-hoc, historical orders may be orphaned.
3. **Churn thresholds are universal:** 180-day threshold assumes all products have similar purchase cycles; subscription products may need 30 days, while furniture may need 365.
4. **RFM quintiles are appropriate:** `NTILE(5)` assumes roughly equal distribution of customers across quintiles; highly skewed distributions (e.g., 90% of customers have 1 order) may produce unintuitive scores.
5. **Refund data is complete:** Assumes `fct_orders.is_refunded` flag is accurate and timely; partial refunds or refunds processed after table load will be missed.

### What Could Break
- **Upstream schema changes:** If `fct_orders` columns are renamed or removed (e.g., `gross_revenue` → `revenue`), query fails.
- **NULL injection:** If `stg_raw_customers.customer_id` contains NULLs, they will appear as rows in output (unlikely but possible).
- **Duplicate customer IDs:** If `stg_raw_customers` has duplicates, output will have multiple rows per customer.
- **Missing order dates:** If `fct_orders.order_date` is NULL, `DATEDIFF()` returns NULL, breaking RFM scoring.
- **Timezone issues:** `GETDATE()` is server timezone; if `fct_orders.order_date` is UTC, recency calculations may be off by 1 day.

---

## Performance Notes

### Join Strategy
- **LEFT JOIN from `stg_raw_customers`:** Ensures all registered customers appear, even if they've never purchased. This is correct but means the table includes prospects (no orders).
- **LEFT JOIN from CTEs:** Both `customer_orders` and `rfm` are left-joined, so missing data is handled gracefully.
- **Implication:** Table size = `stg_raw_customers` row count, not `fct_orders` row count. If you have 1M registered customers but only 500K have purchased, table has 1M rows.

### Expensive Operations
- **`APPROXIMATE COUNT(DISTINCT order_month)`:** Uses HyperLogLog approximation for speed; trades ~1% accuracy for 10–100x faster execution on large datasets. If exact counts are required, replace with `COUNT(DISTINCT order_month)`.
- **`MODE() WITHIN GROUP (ORDER BY ...)`:** Computes most frequent value per customer; O(n log n) per customer. On 1M+ customers, this can be slow. Consider pre-computing in `fct_orders` if performance is an issue.
- **Window functions (`NTILE`):** Require full sort of `customer_orders` CTE; scales as O(n log n). On 10M+ customers, may take minutes.

### Partitioning & Distribution
- **DISTKEY(customer_id):** Distributes rows across nodes by customer ID. Ensures all orders for a customer are co-located, speeding up joins on `customer_id`. Good choice.
- **SORTKEY(customer_id):** Sorts rows by customer ID within each node. Speeds up lookups and range scans on `customer_id`. Good choice.
- **Implication:** Queries filtering by `customer_id` will be fast; queries filtering by `country` or `customer_segment` will require full table scans.

### Estimated Execution Time
- **10K customers, 100K orders:** <1 second
- **1M customers, 10M orders:** 5–30 seconds (depends on cluster size and other workloads)
- **10M customers, 100M orders:** 1–5 minutes (may require query optimization or incremental refresh)

### Optimization Opportunities
1. **Incremental refresh:** Instead of `DROP TABLE IF EXISTS`, use `INSERT INTO` with `WHERE _loaded_at > last_refresh_date` to avoid full recompute.
2. **Pre-aggregate in `fct_orders`:** If `fct_orders` is very large, consider materializing `customer_orders` as a separate table and refreshing it independently.
3. **Parameterize thresholds:** Move churn risk thresholds (30, 90, 180 days) to a config table to avoid SQL rewrites.
4. **Approximate RFM:** For very large datasets, consider sampling customers for RFM scoring rather than computing for all.

---

## Dependencies

### Upstream (Must Run Before This)
1. **marts.fct_orders** — Order fact table must be fully loaded and aggregated. If this table is incrementally refreshed, ensure all historical orders are present before running `dim_customers`.
2. **staging.stg_raw_customers** — Customer master data must be current. If this is a daily snapshot, ensure it includes all active and inactive customers.
3. **Data warehouse infrastructure** — Assumes Redshift (or compatible) with `DISTKEY`, `SORTKEY`, `NTILE`, `MODE()` support.

### Downstream (Depends on This Output)
1. **BI dashboards** — Tableau, Looker, Power BI dashboards query `dim_customers` for customer segmentation, churn analysis, and lifetime value reporting.
2. **Marketing automation** — Segment exports to Salesforce, HubSpot, or Klaviyo for targeted campaigns (e.g., "send email to Champions").
3. **ML models** — Churn prediction models use `recency_score`, `frequency_score`, `churn_risk` as features.
4. **Customer success tools** — CSM platforms use `customer_segment` and `lifetime_revenue` to prioritize accounts.
5. **Ad-hoc analyst queries** — Analysts join `dim_customers` with `fct_orders` or other fact tables for custom analysis.

### External Dependencies
- **GETDATE()** — Assumes server timezone is consistent; if server is rebooted or timezone changes, recency calculations may shift.
- **Email hashing algorithm** — Assumes `stg_raw_customers.email_hash` uses consistent algorithm (e.g., SHA-256); if algorithm changes, hashes will not match.
- **Loyalty tier logic** — `loyalty_tier` is sourced from `stg_raw_customers`; if tier calculation changes upstream, this table will reflect it on next refresh.

### Refresh Cadence
- **Recommended:** Daily (after `fct_orders` and `stg_raw_customers` are refreshed)
- **Minimum:** Weekly (for churn risk to be actionable)
- **Maximum:** Monthly (older data becomes stale for real-time use cases)

### Known Limitations
- **Churn risk is backward-looking:** Based on historical recency; does not predict future churn (use ML model for that).
- **RFM scores are relative:** A customer with `f_score = 5` is in the top 20% of frequency, but may still have low absolute frequency (e.g., 5 orders in 5 years).
- **Segment boundaries are static:** If business strategy changes, SQL must be updated and table rebuilt; no dynamic segmentation.
- **No A/B test attribution:** If customer made purchases in multiple channels/campaigns, preferred channel is the most frequent, not the most profitable.

---

## Maintenance & Monitoring

### Health Checks
- **Row count:** Should equal or exceed `stg_raw_customers` row count (due to left join). If lower, investigate missing customers.
- **NULL counts:** `total_orders`, `lifetime_revenue` should have ~0 NULLs (due to `NVL`). If high, investigate upstream data quality.
- **RFM score distribution:** Each score (1–5) should have ~20% of customers. If skewed, investigate data distribution or `NTILE` logic.
- **Segment distribution:** "Never Purchased" segment should be ~10–30% of customers (varies by business). If >50%, investigate customer acquisition quality.

### Alerting
- **Load time >5 minutes:** Investigate query performance; may need optimization or cluster scaling.
- **Row count change >10%:** Investigate upstream data changes; may indicate data quality issue or business event (e.g., bulk customer import).
- **RFM scores all = 1:** Investigate `fct_orders` data; may indicate missing orders or schema change.

---

## Related Documentation
- **fct_orders:** Order fact table; source of behavioral data
- **stg_raw_customers:** Customer staging table; source of identity data
- **RFM Segmentation Guide:** Business rules for segment definitions (external doc)
- **Churn Prediction Model:** ML model that uses `dim_customers` features (external doc)