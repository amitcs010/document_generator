# transforms.int_order_items Documentation

**Purpose**
Intermediate table that enriches raw order line items with product and order metadata, computing item-level financial metrics including gross/net revenue, cost of goods sold (COGS), gross margin, and margin percentage. Serves as a foundation for downstream order and product analytics.

**Inputs**
- `spectrum.raw_order_items` – Raw order line item records
- `staging.stg_raw_orders` – Staged order headers with customer, date, and channel info
- `staging.stg_raw_products` – Staged product master with SKU, cost, and category data

**Outputs**
- `transforms.int_order_items` – Denormalized order item facts with financial metrics
  - Distributed by `order_id`; sorted by `order_date`, `order_id`
  - Permissions: SELECT granted to `analytics_readers` group

**Key Transformations**
- Type casting to appropriate numeric precision (BIGINT IDs, DECIMAL for currency)
- Revenue calculations: gross revenue, net revenue (discount-adjusted), COGS, gross margin, margin percentage
- Derived flags: `is_discounted`, `is_discontinued_product`
- Inner join on orders (enforces valid order context); left join on products (allows missing product data)
- Data quality filters: non-null order IDs, positive quantities

**Dependencies**
- Upstream: `spectrum.raw_order_items`, `staging.stg_raw_orders`, `staging.stg_raw_products`
- Downstream: Analytics queries, reporting dashboards, product/order aggregations

**Notes**
- Table is dropped and recreated on each run (full refresh pattern)
- Margin percentage defaults to 0 for zero/negative line totals to avoid division errors
- `_loaded_at` timestamp captures load time; `ANALYZE` command updates table statistics for query optimization