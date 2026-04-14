# marts/dim_customers.sql

## Component Overview
- **Layer:** Marts (final consumption layer)
- **Type:** Table (materialized dimension)
- **Schedule:** Not specified in code; infer from orchestration metadata
- **Owner:** Not specified in code; infer from team documentation

---

## Purpose

This component builds a comprehensive **customer dimension table** that enriches raw customer attributes with behavioral metrics, RFM (Recency, Frequency, Monetary) scoring, and predictive segmentation. It serves as the single source of truth for BI tools, analysts, and marketing teams to understand customer value, engagement patterns, and churn risk. The table enables downstream dashboards, cohort analysis, and targeted marketing campaigns by combining static customer profiles with dynamic order history and engagement signals.

---

## Inputs

| Source | Purpose | Why Needed |
|--------|---------|-----------|
| **staging.stg_raw_customers** | Customer master data (PII-masked) including registration date, contact info, loyalty tier, and marketing preferences | Provides the customer dimension base with demographic and account attributes; left-joined to preserve all registered customers even if they've never purchased |
| **marts.fct_orders** | Fact table containing all orders with revenue, margin, refund status, order date, channel, and payment method | Aggregated to compute lifetime value, order frequency, recency, purchase patterns, and refund behavior; enables RFM scoring and churn risk calculation |

---

## Outputs

| Target | Contents | Downstream Consumers |
|--------|----------|---------------------|
| **marts.dim_customers** | 30+ columns including customer identifiers, demographics, order history metrics, RFM scores, segmentation labels, and churn risk flags | BI dashboards (Tableau/Looker), marketing automation platforms, customer analytics reports, cohort analysis tools, data science models for churn prediction |

---

## Key Business Logic

### 1. **Customer Order Aggregation (CTE: customer_orders)**
Aggregates all orders per customer to compute lifetime metrics:
- **Lifetime Revenue & Margin:** Sum of all gross revenue and total margin across customer's order history; used for customer value ranking and LTV calculations
- **Order Frequency:** Total order count; foundational metric for RFM scoring and engagement assessment
- **Recency Baseline:** First and last order dates; used to calculate days since last purchase (recency) and customer tenure
- **Average Order Value:** Mean revenue per order; indicates transaction size and spending pattern consistency
- **Active Months:** Approximate distinct count of order months; measures engagement breadth (how many different months customer purchased)
- **Refund Metrics:** Count of refunded orders; used to calculate refund rate and identify problematic customers
- **Channel & Payment Preferences:** Mode (most frequent value) of order channel and payment method; enables channel-specific marketing and operational insights

**Why:** Aggregation reduces millions of order rows to one row per customer, enabling efficient dimension joins and scoring calculations.

---

### 2. **RFM Scoring (CTE: rfm)**
Computes Recency, Frequency, and Monetary scores using percentile-based ranking:

- **Recency Score (r_score):** `NTILE(5)` ranking of days since last order (ascending, so recent = high score)
  - Customers who purchased recently get scores 4–5; dormant customers get 1–2
  - **Why:** Recent activity indicates engagement; used to identify at-risk customers and active segments

- **Frequency Score (f_score):** `NTILE(5)` ranking of total order count (ascending)
  - High-frequency buyers get scores 4–5; one-time buyers get 1–2
  - **Why:** Repeat purchase behavior indicates loyalty and lifetime value potential

- **Monetary Score (m_score):** `NTILE(5)` ranking of lifetime revenue (ascending)
  - High-spend customers get scores 4–5; low-spend get 1–2
  - **Why:** Revenue contribution indicates customer profitability and retention priority

**Why NTILE(5):** Creates balanced quintile buckets (20% of customers per score) for consistent segmentation across all three dimensions, enabling comparable scoring regardless of absolute metric ranges.

---

### 3. **Customer Segmentation Logic**
Hierarchical business rules map RFM scores to actionable segments:

| Segment | Rule | Business Meaning |
|---------|------|-----------------|
| **Never Purchased** | `total_orders IS NULL` | Registered but no purchase history; acquisition target |
| **Champions** | `r_score ≥ 4 AND f_score ≥ 4 AND m_score ≥ 4` | Recent, frequent, high-value; VIP retention focus |
| **Loyal Customers** | `r_score ≥ 4 AND f_score ≥ 3` | Recent and repeat buyers; upsell/cross-sell candidates |
| **New Customers** | `r_score ≥ 4 AND f_score ≤ 2` | Recent but low frequency; onboarding/engagement focus |
| **Potential Loyalists** | `r_score ≥ 3 AND f_score ≥ 3` | Moderate recency and frequency; nurture for loyalty |
| **At Risk** | `r_score ≤ 2 AND f_score ≥ 3` | Inactive but historically frequent; win-back campaigns |
| **Can't Lose Them** | `r_score ≤ 2 AND f_score ≤ 2 AND m_score ≥ 3` | Inactive, low frequency, but high value; urgent re-engagement |
| **Hibernating** | `r_score ≤ 2 AND f_score ≤ 2` | Inactive and low engagement; reactivation or sunset |
| **Other** | Remaining cases | Edge cases; manual review |

**Why:** Segments enable targeted marketing strategies (e.g., Champions get VIP treatment, At Risk get discounts) and prioritize retention efforts by customer value and engagement state.

---

### 4. **Churn Risk Classification**
Time-based risk buckets derived from days since last order:

| Risk Level | Condition | Days Inactive | Action |
|------------|-----------|---------------|--------|
| **no_purchase** | Never purchased | N/A | Acquisition campaigns |
| **active** | Last order ≤ 30 days | 0–30 | Maintain engagement |
| **low_risk** | Last order 31–90 days | 31–90 | Gentle re-engagement |
| **medium_risk** | Last order 91–180 days | 91–180 | Targeted win-back |
| **high_risk** | Last order > 180 days | 180+ | Urgent intervention or sunset |

**Why:** Provides simple, actionable risk tiers for marketing automation and retention prioritization; thresholds (30/90/180 days) are industry-standard engagement windows.

---

### 5. **Refund Rate Calculation**
```
refund_rate_pct = (refund_count / total_orders) * 100
```
- Handles division by zero with `CASE` logic (returns 0 if no orders)
- Rounded to 2 decimal places for readability
- **Why:** Identifies problematic customers with high return rates; flags potential fraud, quality issues, or misaligned expectations

---

### 6. **Null Handling Strategy**
Extensive use of `NVL()` (Redshift equivalent of `COALESCE`) ensures:
- Customers with no orders get 0 for counts/sums (not NULL), enabling arithmetic operations downstream
- Categorical fields (channel, payment) default to `'none'` for clarity
- RFM scores default to 1 (lowest quintile) for non-purchasers, ensuring they don't break downstream logic
- **Why:** Prevents NULL propagation in BI tools and ensures all 30+ columns are always populated for consistent reporting

---

## Column Descriptions

### Customer Identifiers & Demographics
| Column | Type | Description | Example |
|--------|------|-------------|---------|
| **customer_id** | INT | Unique customer identifier; primary key | `12345` |
| **email_hash** | VARCHAR | SHA-256 hash of email for privacy compliance | `a1b2c3d4e5f6...` |
| **email_domain** | VARCHAR | Email domain for cohort analysis | `gmail.com` |
| **first_name_masked** | VARCHAR | First name with PII masking (e.g., first letter + asterisks) | `J****` |
| **last_name_masked** | VARCHAR | Last name with PII masking | `D****` |
| **country** | VARCHAR | Customer country; enables geo-segmentation | `US`, `CA`, `GB` |
| **state** | VARCHAR | State/province for regional analysis | `CA`, `NY` |
| **registration_date** | DATE | Account creation date; tenure baseline | `2022-03-15` |
| **loyalty_tier** | VARCHAR | Program tier (e.g., Bronze, Silver, Gold); from source | `Gold` |

### Order History Metrics
| Column | Type | Description | Example |
|--------|------|-------------|---------|
| **total_orders** | INT | Lifetime order count; frequency metric | `42` |
| **lifetime_revenue** | DECIMAL(18,2) | Sum of all gross revenue; LTV indicator | `5432.50` |
| **lifetime_margin** | DECIMAL(18,2) | Sum of all profit margin; profitability metric | `1200.75` |
| **first_order_date** | DATE | Earliest purchase date; tenure calculation | `2022-04-01` |
| **last_order_date** | DATE | Most recent purchase; recency baseline | `2024-01-20` |
| **avg_order_value** | DECIMAL(18,2) | Mean revenue per order; transaction size | `129.35` |
| **active_months** | INT | Approximate distinct months with purchases; engagement breadth | `18` |
| **refund_count** | INT | Number of refunded orders; quality/satisfaction indicator | `2` |
| **total_units_purchased** | INT | Sum of all units across orders; volume metric | `156` |
| **preferred_channel** | VARCHAR | Most frequent order channel; operational insight | `web`, `mobile`, `store` |

### RFM Scores & Segmentation
| Column | Type | Description | Example |
|--------|------|-------------|---------|
| **recency_score** | INT | Quintile rank (1–5) of days since last order; 5 = most recent | `5` |
| **frequency_score** | INT | Quintile rank (1–5) of total orders; 5 = most frequent | `4` |
| **monetary_score** | INT | Quintile rank (1–5) of lifetime revenue; 5 = highest spend | `5` |
| **rfm_total** | INT | Sum of three RFM scores; composite engagement metric (3–15 range) | `14` |
| **customer_segment** | VARCHAR | Business segment label derived from RFM rules | `Champions`, `At Risk`, `Hibernating` |
| **churn_risk** | VARCHAR | Risk classification based on recency; actionable tier | `active`, `high_risk`, `no_purchase` |
| **refund_rate_pct** | DECIMAL(5,2) | Percentage of orders refunded; quality metric | `4.76` |

### Metadata
| Column | Type | Description | Example |
|--------|------|-------------|---------|
| **_loaded_at** | TIMESTAMP | Table load timestamp; data freshness indicator | `2024-01-21 03:45:00` |

---

## Data Quality & Edge Cases

### Null Handling
- **Never-purchased customers:** Appear in output (left join from `stg_raw_customers`) with `total_orders = 0`, `customer_segment = 'Never Purchased'`, `churn_risk = 'no_purchase'`
  - **Risk:** If `stg_raw_customers` contains test/invalid accounts, they inflate the "Never Purchased" segment; recommend filtering by `registration_date` or account status upstream
  
- **Customers with no recent orders:** RFM scores default to 1 (lowest quintile) via `NVL(r.r_score, 1)`, ensuring they don't break downstream calculations
  - **Risk:** If a customer has orders but RFM CTE returns NULL (e.g., due to upstream data loss), they'll be incorrectly scored as lowest quintile; validate RFM CTE completeness

### Deduplication Strategy
- **No explicit deduplication:** Assumes `customer_id` is unique in `stg_raw_customers` and `marts.fct_orders` is already deduplicated
  - **Risk:** If `stg_raw_customers` contains duplicate customer records (e.g., from failed merges), the LEFT JOIN will create duplicate rows in output; recommend adding `DISTINCT` or upstream dedup validation
  
- **Aggregation in CTEs:** `GROUP BY customer_id` in `customer_orders` CTE ensures one row per customer; `NTILE()` window functions in `rfm` CTE operate on already-grouped data
  - **Assumption:** All customers in `customer_orders` have unique `customer_id` values

### Data Assumptions
1. **Order dates are valid:** Recency and churn risk calculations assume `order_date` and `last_order_date` are accurate; if future-dated orders exist, recency will be negative (edge case)
   - **Mitigation:** Add upstream validation: `WHERE order_date <= GETDATE()`

2. **Revenue metrics are non-negative:** Calculations assume `gross_revenue`, `total_margin`, and `total_units` are ≥ 0; negative values (e.g., from refunds) will skew LTV
   - **Mitigation:** Validate in `marts.fct_orders` that refunds are handled as separate rows with negative amounts, not as negative values in original orders

3. **RFM scores are always 1–5:** `NTILE(5)` guarantees this, but if customer counts are very small (< 5), some quintiles may be empty or unbalanced
   - **Mitigation:** Document minimum customer count requirement for valid RFM scoring

4. **Email domain is populated:** `email_domain` is used for cohort analysis; if NULL, it will appear as `NULL` in output
   - **Mitigation:** Add `NVL(email_domain, 'unknown')` if domain extraction fails upstream

### Potential Breakage Points
- **If `marts.fct_orders` is truncated/reloaded:** Recency and churn risk will reset; customers marked "active" may suddenly become "high_risk" if order history is lost
  - **Mitigation:** Implement incremental loads or validate row counts before/after refresh

- **If `stg_raw_customers` loses historical records:** Customers who unregistered will disappear; tenure calculations will be incorrect
  - **Mitigation:** Maintain a slowly-changing dimension (SCD Type 2) with effective dates

- **If `MODE()` function returns NULL:** `preferred_channel` or `preferred_payment` will be NULL instead of `'none'` if all orders have NULL values
  - **Mitigation:** Ensure `stg_raw_customers` and `marts.fct_orders` have NOT NULL constraints on these columns

- **If `GETDATE()` is called multiple times:** Churn risk calculations use `GETDATE()` in both the `rfm` CTE and main SELECT; if query runs across midnight, values may be inconsistent
  - **Mitigation:** Assign `GETDATE()` to a variable at query start: `SET @run_date = GETDATE()`

---

## Performance Notes

### Join Strategy
```sql
FROM staging.stg_raw_customers c
LEFT JOIN customer_orders co ON c.customer_id = co.customer_id
LEFT JOIN rfm r ON c.customer_id = r.customer_id
```

- **Left join from customers:** Preserves all registered customers (including never-purchasers); ensures complete customer dimension
- **Two sequential LEFT JOINs:** Both CTEs are pre-aggregated to one row per customer, so joins are efficient (no Cartesian products)
- **Join keys:** `customer_id` is likely indexed in both source tables; join should use hash join or merge join (efficient)
- **Implication:** If `stg_raw_customers` has 1M rows and `fct_orders` has 100M rows, the aggregation in `customer_orders` CTE reduces it to 1M rows before join, avoiding full table scan of orders

### Expensive Operations
1. **`APPROXIMATE COUNT(DISTINCT order_month)` in customer_orders CTE:**
   - Uses Redshift's approximate distinct count (HyperLogLog algorithm) for performance
   - **Trade-off:** Accuracy ±2% for speed; suitable for "active months" metric but not for exact counts
   - **Alternative:** Use exact `COUNT(DISTINCT order_month)` if precision is critical (slower)

2. **`MODE() WITHIN GROUP (ORDER BY ...)` for preferred channel/payment:**
   - Requires sorting within each customer group; O(n log n) complexity per customer
   - **Risk:** If customers have thousands of orders, this becomes expensive; consider pre-computing mode in `fct_orders` instead
   - **Alternative:** Use `FIRST_VALUE()` with `ORDER BY order_date DESC` to get most recent channel (faster)

3. **`NTILE(5)` window functions in rfm CTE:**
   - Requires full sort of all customers by recency, frequency, and monetary (three separate sorts)
   - **Complexity:** O(n log n) for each window function; acceptable for typical customer counts (< 10M)
   - **Implication:** If customer base grows to 100M+, consider materializing RFM scores incrementally

### Partitioning & Distribution
```sql
CREATE TABLE marts.dim_customers
DISTKEY(customer_id)
SORTKEY(customer_id)
```

- **DISTKEY(customer_id):** Distributes rows across Redshift cluster nodes by customer_id hash
  - **Why:** Enables efficient joins with `fct_orders` (also distributed by customer_id) and future fact table joins; minimizes data movement
  - **Implication:** Queries joining on `customer_id` will be co-located (fast); queries joining on other columns (e.g., `email_hash`) will require redistribution (slow)

- **SORTKEY(customer_id):** Sorts rows within each node by customer_id
  - **Why:** Enables efficient range scans and lookups by customer_id; improves compression
  - **Implication:** Queries filtering on `customer_id` will be fast; queries filtering on `customer_segment` or `churn_risk` will require full table scan (consider adding secondary sort keys if these are common filters)

### Table Size Estimate
- **Columns:** ~30 columns, mostly INT/VARCHAR/DATE
- **Row size:** ~500 bytes per customer (rough estimate)
- **For 1M customers:** ~500 MB; for 10M customers: ~5 GB
- **Recommendation:** Monitor table size with `SELECT pg_size_pretty(pg_total_relation_size('marts.dim_customers'))`

### Query Execution Plan Considerations
- **CTE materialization:** Redshift may materialize `customer_orders` and `rfm` CTEs to disk if they're large; check query plan with `EXPLAIN`
- **Recommendation:** If CTEs are expensive, consider materializing them as intermediate tables or using `WITH ... AS (... MATERIALIZED)` hint (Redshift 8.1+)

---

## Dependencies

### Upstream (Must Run Before This Component)
1. **staging.stg_raw_customers**
   - Provides customer master data with PII masking
   - Must include: `customer_id`, `email_hash`, `email_domain`, `first_name_masked`, `last_name_masked`, `country`, `state`, `city`, `postal_code_masked`, `registration_date`, `last_login_date`, `marketing_opt_in`, `loyalty_tier`, `days_since_registration`
   - Refresh frequency: Daily or on-demand (infer from orchestration)
   - **SLA:** Must complete before `marts.dim_customers` job starts

2. **marts.fct_orders**
   - Provides order-level facts with revenue, margin, refund status, dates, channels, and payment methods
   - Must include: `customer_id`, `order_id`, `order_date`, `order_month`, `gross_revenue`, `total_margin`, `is_refunded`, `total_units`, `order_channel`, `payment_method`
   - Refresh frequency: Daily (infer from typical data warehouse patterns)
   - **SLA:** Must be complete and deduplicated before aggregation in `customer_orders` CTE

### Downstream (Components That Depend on This Output)
1. **BI Dashboards & Reports**
   - Tableau, Looker, or similar tools query `marts.dim_customers` for customer analytics, segmentation, and RFM visualizations
   - **Expected query patterns:** Filters on `customer_segment`, `churn_risk`, `country`, `loyalty_tier`; aggregations on `lifetime_revenue`, `total_orders`
   - **SLA:** Table must be available by 6 AM for morning dashboards (infer from business hours)

2. **Marketing Automation Platforms**
   - Segment exports (e.g., "Champions" or "At Risk" customers) for email campaigns, SMS, or ads
   - **Expected usage:** Daily exports of `customer_id`, `email_hash`, `customer_segment`, `churn_risk`
   - **SLA:** Must be refreshed daily before marketing jobs run (typically 7 AM)

3. **Data Science Models**
   - Churn prediction, LTV forecasting, or propensity models use RFM scores, segment labels, and behavioral metrics
   - **Expected features:** `recency_score`, `frequency_score`, `monetary_score`, `refund_rate_pct`, `active_months`, `avg_order_value`
   - **SLA:** Must be available for model retraining (weekly or monthly)

4. **Customer Service & Operations**
   - Support teams use `customer_segment` and `churn_risk` to prioritize interactions and offers
   - **Expected usage:** Real-time lookups by `customer_id` or `email_hash`
   - **SLA:** Must be queryable with < 1 second latency (ensure indexes on `customer_id`, `email_hash`)

### External Dependencies
- **Redshift Cluster:** Must be running and accessible; assumes Redshift-specific functions (`NTILE()`, `MODE()`, `APPROXIMATE COUNT(DISTINCT)`, `GETDATE()`, `DATEDIFF()`)
- **IAM/Permissions:** Assumes `analytics_readers` and `bi_team` groups exist in Redshift for `GRANT` statements
- **System Clock:** Churn risk calculations depend on `GETDATE()` accuracy; ensure Redshift server time is synchronized with NTP

---

## Maintenance & Monitoring

### Recommended Monitoring
- **Row count:** Track daily to detect data loss or duplication
  ```sql
  SELECT COUNT(*) FROM marts.dim_customers;
  ```
- **Segment distribution:** Monitor segment balance to detect RFM scoring anomalies
  ```sql
  SELECT customer_segment, COUNT(*) FROM marts.dim_customers GROUP BY customer_segment;
  ```
- **Null rates:** Check for unexpected NULLs in key columns
  ```sql
  SELECT COUNT(*) FILTER (WHERE lifetime_revenue IS NULL) FROM marts.dim_customers;
  ```
- **Refresh duration:** Track query execution time to detect performance degradation
  ```sql
  -- Log in orchestration tool (e.g., Airflow, dbt)
  ```

### Recommended Indexes (if not already present)
```sql
CREATE INDEX idx_dim_customers_segment ON marts.dim_customers(customer_segment);
CREATE INDEX idx_dim_customers_churn_risk ON marts.dim_customers(churn_risk);
CREATE INDEX idx_dim_customers_email_hash ON marts.dim_customers(email_hash);
```

### Refresh Strategy
- **Full refresh:** Drop and recreate table daily (current approach)
  - **Pros:** Simple, no incremental logic, always consistent
  - **Cons:** Expensive for large tables; blocks queries during refresh
- **Alternative (Incremental):** Maintain SCD Type 2 with effective dates; only update changed customers
  - **Pros:** Faster refresh, preserves historical segments
  - **Cons:** More complex logic, requires tracking changes