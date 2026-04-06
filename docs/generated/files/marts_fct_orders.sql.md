# marts.fct_orders Documentation

**Purpose**
Order-level fact table serving as the primary analytics table for the BI team. Combines order headers, line items, customer attributes, and session attribution to enable comprehensive order analysis across revenue, margins, customer lifecycle, and conversion channels.

**Inputs**
- `staging.stg_raw_orders` – Order header data (order ID, customer ID, dates, amounts, status, channels)
- `staging.stg_raw_customers` – Customer attributes (loyalty tier, registration date, country)
- `transforms.int_order_items` – Line-item metrics (quantity, revenue, COGS, margins, discounts)
- `transforms.int_customer_sessions` – Session data for attribution (referrer, device, engagement metrics)

**Outputs**
- `marts.fct_orders` – Denormalized fact table with 50+ columns; distributed on `order_id`, sorted on `order_date`

**Key Transformations**
- Aggregates line items into order-level metrics (item count, revenue, margins, discounted items)
- Calculates customer tenure and lifecycle stage (New/Growing/Established/Loyal) at order time
- Attributes orders to converting sessions (last session within 24 hours before purchase)
- Derives flags for coupon usage, discounts, refunds, and international orders
- Extracts time dimensions (day of week, hour, month, week)
- Filters out pending/fraud-review orders

**Dependencies**
- Requires upstream staging and intermediate tables to be populated
- Redshift-specific syntax (DISTKEY, SORTKEY, LISTAGG, DATEADD, DATE_PART)

**Notes**
- Grants SELECT access to `analytics_readers` and `bi_team` groups
- Runs ANALYZE post-load for query optimization
- Uses LEFT JOINs for customers and sessions to preserve orders without matching data; defaults to 'unknown' for attribution
- Attribution window: 24 hours prior to order; requires session with `purchase_count > 0`