# marts.dim_customers Documentation

**Purpose**
Customer dimension table enriched with behavioral analytics, RFM segmentation, and lifetime value metrics. Enables customer analytics, marketing segmentation, and churn prediction by combining customer attributes with transactional history and derived scoring models.

**Inputs**
- `staging.stg_raw_customers` – Customer master data (demographics, registration, contact preferences)
- `marts.fct_orders` – Order fact table (transactions, revenue, channels, refunds)

**Outputs**
- `marts.dim_customers` – Denormalized customer dimension (Redshift, DISTKEY/SORTKEY on customer_id)

**Key Transformations**
- **Order aggregation**: Total orders, lifetime revenue/margin, order dates, average order value, active months, refund counts, preferred channel/payment
- **RFM scoring**: Recency (days since last order), Frequency (order count), Monetary (lifetime revenue) scored 1–5 via NTILE
- **Segmentation**: 8-tier customer segment (Champions, Loyal, New, At Risk, Hibernating, etc.) based on RFM thresholds
- **Churn risk**: 5-tier classification (active, low/medium/high risk, no_purchase) based on days since last order
- **Refund rate**: Percentage of refunded orders per customer
- **Data masking**: PII fields hashed/masked (email, names, postal code)

**Dependencies**
- Requires `marts.fct_orders` and `staging.stg_raw_customers` to exist
- Redshift-specific syntax (DISTKEY, SORTKEY, NTILE, MODE, DATEDIFF)

**Notes**
- Table recreated on each load (DROP TABLE IF EXISTS)
- NVL defaults handle customers with no order history
- Optimized for analytics queries via distribution and sort keys
- Permissions granted to `analytics_readers` and `bi_team` groups
- ANALYZE command updates table statistics post-load