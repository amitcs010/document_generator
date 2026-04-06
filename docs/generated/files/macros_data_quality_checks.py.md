# macros/data_quality_checks.py

## Component Overview
- **Layer:** Utilities — Reusable scripts, macros, and helper functions
- **Type:** Python macro / monitoring script
- **Schedule:** Post-ETL execution (triggered by Airflow DAG completion)
- **Owner:** Data Engineering / Data Quality team

---

## Purpose

This macro executes a suite of automated data quality checks against the Redshift analytics warehouse immediately after each ETL pipeline run completes. It validates that critical data dimensions, facts, and metrics meet predefined thresholds and business rules, then logs results to a centralized quality audit table and triggers alerts for failures. This serves as a real-time safeguard to catch data anomalies, pipeline failures, and upstream data quality issues before they propagate to downstream analytics and business intelligence systems.

---

## Inputs

### Data Sources (Redshift Tables Queried)

- **marts.fct_orders** — Fact table of all orders; checked for row volume, null values, and revenue outliers to ensure daily order loads are complete and valid
- **marts.dim_customers** — Customer dimension; checked for duplicate customer_ids to ensure referential integrity and proper dimension management
- **marts.dim_products** — Product dimension; checked for missing or invalid unit costs on active products to ensure pricing data completeness
- **marts.fct_daily_revenue** — Daily revenue aggregate; checked for freshness to ensure the ETL pipeline is running on schedule
- **transforms.int_customer_sessions** — Intermediate sessions table; checked for invalid event counts to catch data transformation errors
- **transforms.int_order_items** — Intermediate order items table; checked for extreme margin percentages to detect pricing or calculation anomalies

### Configuration Inputs

- **Environment variables** — Redshift connection credentials (`REDSHIFT_HOST`, `REDSHIFT_PORT`, `REDSHIFT_DB`, `REDSHIFT_USER`, `REDSHIFT_PASS`)
- **CHECKS list** — Hardcoded check definitions (name, SQL, threshold, operator, severity, description)

---

## Outputs

### Primary Output: quality_log Table (Redshift)

Each check execution writes one row to `quality_log` (assumed destination based on docstring):

```
check_name          VARCHAR(100)    — Unique identifier for the check (e.g., "orders_not_empty")
table               VARCHAR(200)    — Schema-qualified table name being validated
description         VARCHAR(500)    — Human-readable check description
severity            VARCHAR(20)     — "critical" or "warning" classification
expected            VARCHAR(100)    — Expected condition as string (e.g., ">= 100")
actual              NUMERIC         — Actual value returned by the check query
passed              BOOLEAN         — True if actual satisfies the condition, False otherwise
error               VARCHAR(1000)   — Exception message if query execution failed (NULL on success)
run_at              TIMESTAMP       — UTC timestamp when the check executed
```

### Secondary Output: Console Logs

- Real-time status messages printed to stdout: `[PASS] check_name: actual=X (expected OP Y)` or `[FAIL] ...`
- Used by Airflow task logs for monitoring and debugging

### Tertiary Output: Alert Triggers (Implied)

- Failures with `severity = "critical"` should trigger PagerDuty/Slack alerts (implementation not shown in this file)
- Warnings may trigger dashboard notifications or email summaries

---

## Key Business Logic

### 1. **Order Volume Validation** (`orders_not_empty`)
- **Logic:** Counts orders placed yesterday; fails if fewer than 100 orders
- **Why:** Detects pipeline stalls, upstream data source failures, or business anomalies (e.g., system outage). Threshold of 100 is a business-defined minimum daily order volume
- **Severity:** Critical — indicates potential revenue loss or system failure

### 2. **Order Revenue Completeness** (`orders_no_null_revenue`)
- **Logic:** Counts orders from the last 3 days with NULL `gross_revenue`; fails if any exist
- **Why:** Revenue is a core business metric; NULL values indicate incomplete ETL transformations or data quality issues in source systems
- **Severity:** Critical — corrupted revenue data breaks financial reporting

### 3. **Order Revenue Sanity Check** (`orders_revenue_range`)
- **Logic:** Counts orders with negative or >$50,000 revenue; fails if more than 0 exist
- **Why:** Detects data entry errors, pricing calculation bugs, or fraudulent transactions. $50K threshold is business-defined upper bound for typical orders
- **Severity:** Warning — outliers warrant investigation but may be legitimate (e.g., bulk orders)

### 4. **Customer Dimension Uniqueness** (`customers_unique`)
- **Logic:** Compares total row count to distinct `customer_id` count; fails if they differ
- **Why:** Dimension tables must have one row per business entity. Duplicates cause incorrect joins, inflated customer counts, and corrupted analytics
- **Severity:** Critical — dimension integrity is foundational to all downstream reporting

### 5. **Product Cost Validation** (`products_have_cost`)
- **Logic:** Counts active products with NULL or ≤0 `unit_cost`; fails if any exist
- **Why:** Cost data is required for margin calculations and profitability analysis. Active products must have valid costs
- **Severity:** Warning — missing costs prevent accurate margin reporting but don't break the pipeline

### 6. **Daily Revenue Freshness** (`daily_revenue_freshness`)
- **Logic:** Calculates days between max `revenue_date` and today; fails if >2 days stale
- **Why:** Ensures the ETL pipeline is running regularly and revenue aggregations are current. 2-day lag accommodates batch processing windows
- **Severity:** Critical — stale data indicates pipeline failure or scheduling issues

### 7. **Session Event Count Validation** (`sessions_event_count`)
- **Logic:** Counts sessions with `event_count ≤ 0`; fails if any exist
- **Why:** Sessions must contain at least 1 event by definition. Zero or negative counts indicate transformation errors in session aggregation logic
- **Severity:** Warning — suggests bugs in intermediate layer but may not affect final marts

### 8. **Margin Percentage Sanity Check** (`margin_sanity`)
- **Logic:** Counts order items with margin <-50% or >99%; fails if more than 10 exist
- **Why:** Detects pricing calculation errors or data anomalies. Negative margins indicate loss-making items; >99% margins are unrealistic. Threshold of 10 allows for rare outliers
- **Severity:** Warning — extreme margins warrant investigation but small counts may be acceptable

---

## Column Descriptions

### Output Columns (quality_log table)

| Column | Type | Description | Example |
|--------|------|-------------|---------|
| **check_name** | VARCHAR(100) | Unique identifier for the data quality check | `orders_not_empty` |
| **table** | VARCHAR(200) | Schema-qualified name of the table being validated | `marts.fct_orders` |
| **description** | VARCHAR(500) | Business-friendly explanation of what the check validates | `Yesterday should have at least 100 orders` |
| **severity** | VARCHAR(20) | Priority level: "critical" (blocks downstream use) or "warning" (investigate but non-blocking) | `critical` |
| **expected** | VARCHAR(100) | Expected condition as a human-readable string | `>= 100` |
| **actual** | NUMERIC | The actual value returned by the check query | `247` |
| **passed** | BOOLEAN | True if actual satisfies the condition; False otherwise | `true` |
| **error** | VARCHAR(1000) | Exception message if the check query failed; NULL on success | `relation "marts.fct_orders" does not exist` |
| **run_at** | TIMESTAMP | UTC timestamp when the check executed (ISO 8601 format) | `2024-01-15T14:32:18.123456+00:00` |

---

## Data Quality & Edge Cases

### Null Handling
- **Check queries:** Most checks explicitly filter for NULL values (e.g., `WHERE gross_revenue IS NULL`). The `margin_sanity` check does not filter NULLs, which could cause unexpected behavior if margin_pct contains NULLs
- **Result logging:** If a check query fails (exception), `actual` is set to NULL and `error` contains the exception message
- **Assumption:** All threshold comparisons assume `actual_value` is numeric; non-numeric results will cause type errors in `evaluate_check()`

### Deduplication Strategy
- **Customer uniqueness check:** Uses `COUNT(*) - COUNT(DISTINCT customer_id)` to detect duplicates without removing them (read-only validation)
- **No deduplication in other checks:** Checks count raw rows; if upstream tables have duplicates, counts will be inflated

### Key Assumptions About Upstream Data
1. **Date columns are valid:** Checks use `CURRENT_DATE`, `CURRENT_DATE - 1`, `DATEDIFF()` assuming date columns are properly typed and populated
2. **Numeric columns are numeric:** Revenue, cost, and margin columns are assumed to be numeric types; string or mixed types will cause comparison failures
3. **Table schemas are stable:** Check queries reference specific column names; schema changes (renamed/dropped columns) will cause query failures
4. **Timezone consistency:** `run_at` is logged in UTC; assumes Redshift and application servers are timezone-aware

### What Could Break If Upstream Data Changes
- **Column renames:** Any change to `customer_id`, `gross_revenue`, `unit_cost`, `margin_pct`, `event_count`, `revenue_date` will cause check queries to fail
- **Table renames/moves:** Checks reference specific schema paths (e.g., `marts.fct_orders`); moving tables to different schemas breaks checks
- **Data type changes:** Converting numeric columns to strings will cause comparison operators to fail
- **Null handling changes:** If upstream ETL starts populating previously-NULL columns, checks may flip from pass to fail (e.g., if `unit_cost` is suddenly populated with 0)
- **Business logic changes:** If order volume naturally drops below 100/day or margin calculations change, thresholds become stale and generate false positives

### Incomplete Error Handling
- **Partial failures:** If one check fails, others still execute (good). However, if the Redshift connection itself fails, the entire script crashes without logging partial results
- **SQL injection risk:** Check SQL is hardcoded, so no injection risk, but if checks were dynamically generated from user input, this would be vulnerable
- **Missing connection cleanup:** If an exception occurs during `run_checks()`, the database connection may not be properly closed (no `finally` block)

---

## Performance Notes

### Query Patterns & Efficiency
- **Full table scans:** All checks perform full table scans (no WHERE clause filtering by partition or index). For large fact tables (millions of rows), these can be expensive
  - `orders_not_empty`: Scans `fct_orders` filtered by `order_date = CURRENT_DATE - 1` (good — partition pruning likely)
  - `orders_no_null_revenue`: Scans `fct_orders` filtered by `order_date >= CURRENT_DATE - 3` (good — 3-day window)
  - `customers_unique`: Full scan of `dim_customers` with COUNT(*) and COUNT(DISTINCT) — expensive for large dimensions
  - `margin_sanity`: Full scan of `int_order_items` with range filter — no partition pruning

### Join Strategies
- **No joins:** All checks are single-table queries; no join overhead

### Aggregation Overhead
- **COUNT(DISTINCT):** The `customers_unique` check uses `COUNT(DISTINCT customer_id)`, which requires a full table scan and hash aggregation. For a dimension with millions of rows, this is expensive
- **DATEDIFF aggregation:** The `daily_revenue_freshness` check uses `MAX(revenue_date)` — efficient if `revenue_date` is indexed

### Redshift-Specific Considerations
- **Connection pooling:** Script creates a new connection per run; no connection pooling. For frequent runs, this adds overhead
- **Cursor overhead:** Single cursor used sequentially; acceptable for 8 checks but could be parallelized
- **No result caching:** Each check re-queries tables; no caching of intermediate results

### Recommendations for Optimization
1. **Add partition pruning:** Ensure fact table queries filter by date columns to leverage Redshift's zone maps
2. **Index dimension keys:** Add indexes on `customer_id` and `product_id` to speed up COUNT(DISTINCT) operations
3. **Batch checks:** Group related checks into fewer queries (e.g., combine multiple `fct_orders` checks into one query)
4. **Parallel execution:** Use threading or async to run independent checks concurrently
5. **Connection pooling:** Reuse connections across multiple check runs

---

## Dependencies

### Upstream Dependencies
**Components that must complete before this macro runs:**

- **Entire ETL DAG** — All data transformations, loads, and marts must be fully populated before quality checks execute
  - `stg_orders` → `marts.fct_orders` (order fact table)
  - `stg_customers` → `marts.dim_customers` (customer dimension)
  - `stg_products` → `marts.dim_products` (product dimension)
  - `transforms.int_customer_sessions` (intermediate sessions layer)
  - `transforms.int_order_items` (intermediate order items layer)
  - `marts.fct_daily_revenue` (daily revenue aggregate)

- **Redshift cluster availability** — Cluster must be running and accessible via environment-configured credentials

### Downstream Dependencies
**Components that depend on this macro's output:**

- **Airflow DAG orchestration** — Airflow task status (pass/fail) determines whether downstream tasks execute or trigger alerts
- **Data quality alerting system** — Alert handler (not shown) consumes `quality_log` table to send Slack/PagerDuty notifications for critical failures
- **Data quality dashboard** — BI tool queries `quality_log` to display check history, trends, and SLA compliance
- **Data governance/lineage tools** — May consume quality metadata for data catalog enrichment
- **Stakeholder reports** — Data quality SLA reports aggregated from `quality_log` for management visibility

### External Dependencies
**APIs, services, and configurations:**

- **Redshift cluster** — AWS Redshift data warehouse (host, port, database, credentials from environment variables)
- **Environment variables** — Configuration injected at runtime:
  - `REDSHIFT_HOST` (default: `my-cluster.xxxx.us-east-1.redshift.amazonaws.com`)
  - `REDSHIFT_PORT` (default: `5439`)
  - `REDSHIFT_DB` (default: `analytics`)
  - `REDSHIFT_USER` (default: `etl_user`)
  - `REDSHIFT_PASS` (no default — must be provided)
- **psycopg2 library** — Python PostgreSQL adapter (Redshift is PostgreSQL-compatible)
- **Python standard library** — `os`, `json`, `datetime`, `timezone`

### Implicit Dependencies (Not Shown)
- **quality_log table** — Must exist in Redshift before results can be written (creation script not included)
- **Alert handler** — Downstream process that reads `quality_log` and triggers notifications (not included in this file)
- **Airflow integration** — This script is called by Airflow; assumes Airflow task context and error handling

---

## Known Limitations & Future Improvements

### Current Limitations
1. **Hardcoded checks:** Adding new checks requires code changes; no dynamic check configuration
2. **No result persistence:** Results are printed to console but not automatically written to `quality_log` (code is incomplete)
3. **No alerting logic:** Failures are logged but alerts are not triggered (assumed to be handled externally)
4. **Single-threaded execution:** Checks run sequentially; no parallelization
5. **No retry logic:** Failed checks are not retried; transient connection issues cause immediate failure
6. **Limited operator support:** Only 5 comparison operators; no support for regex, custom functions, or complex conditions
7. **No baseline/trend analysis:** Checks are static thresholds; no detection of gradual degradation or anomalies relative to historical patterns

### Recommended Enhancements
1. **Externalize check definitions:** Move CHECKS to a YAML/JSON config file or database table for easier maintenance
2. **Implement result persistence:** Add code to write results to `quality_log` table (currently missing)
3. **Add alerting integration:** Trigger Slack/PagerDuty for critical failures
4. **Implement retry logic:** Retry failed checks with exponential backoff
5. **Add parallel execution:** Use `concurrent.futures` or async to run checks concurrently
6. **Support advanced operators:** Add regex matching, custom Python functions, and statistical tests
7. **Implement anomaly detection:** Compare actual values to historical baselines to detect gradual degradation
8. **Add check metadata:** Track check creation date, owner, last modified, and change history