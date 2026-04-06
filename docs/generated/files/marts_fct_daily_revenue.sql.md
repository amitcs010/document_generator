# marts.fct_daily_revenue Documentation

**Purpose**
Daily revenue fact table aggregating order metrics by product category, subcategory, brand, channel, country, and payment method. Serves as the primary data source for executive dashboards and financial reporting, providing volume, revenue, margin, and discount analytics with day-over-day and week-over-week comparisons.

**Inputs**
- `transforms.int_order_items` – Order line items with product hierarchy, quantities, and financial metrics
- `staging.stg_raw_orders` – Order headers with dates, channels, geography, and payment details

**Outputs**
- `marts.fct_daily_revenue` – Redshift table, distributed on `revenue_date`, sorted by `revenue_date` and `category`

**Key Transformations**
- Filters to completed/valid orders (excludes pending_payment, fraud_review, cancelled)
- Aggregates volume metrics: order count, customer count, units sold, unique products
- Calculates financial metrics: gross/net revenue, COGS, gross margin, margin percentage
- Derives averages: AOV, unit price
- Computes discount penetration: discounted revenue and percentage of total
- Adds YoY comparisons: revenue delta vs. previous day and previous week (window functions)
- Includes load timestamp for lineage tracking

**Dependencies**
- Upstream: `transforms.int_order_items`, `staging.stg_raw_orders`
- Downstream: Executive dashboards, finance reporting tools, BI platforms

**Notes**
- Distributed key on `revenue_date` optimizes time-series queries; sort key supports common filter patterns
- Window functions partition by category and channel for granular trend analysis
- NULLIF guards against division-by-zero errors in ratio calculations
- Post-load grants restrict access to analytics_readers, bi_team, and finance_team groups
- ANALYZE command updates table statistics for query optimization