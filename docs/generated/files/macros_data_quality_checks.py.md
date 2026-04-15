# macros/data_quality_checks.py

## Component Overview
- **Layer:** Utilities — Reusable scripts, macros, and helper functions
- **Type:** Python macro / monitoring script
- **Schedule:** Post-ETL execution (triggered by Airflow DAG completion)
- **Owner:** Data Engineering / Data Quality team

---

## Purpose

This macro executes a suite of automated data quality checks against the Redshift analytics warehouse immediately after each ETL pipeline run completes. It validates that critical data dimensions, facts, and metrics meet expected thresholds and business rules—catching data anomalies, pipeline failures, and upstream data quality issues before they propagate to downstream consumers (analytics, reporting, ML models). Results are logged to a quality audit table and critical failures trigger alerting mechanisms to notify the data team of issues requiring immediate investigation.

---

## Inputs

**Source: Redshift Analytics Warehouse**
- **marts.fct_orders** — Fact table of transactional orders; checked for row volume, null values, and revenue range validity
- **marts.dim_customers** — Customer dimension; checked for duplicate customer_ids indicating ETL logic errors
- **marts.dim_products** — Product dimension; checked for missing or invalid unit costs on active products
- **marts.fct_daily_revenue** — Daily aggregated revenue fact table; checked for data freshness (staleness detection)
- **transforms.int_customer_sessions** — Intermediate session table; checked for invalid event counts
- **transforms.int_order_items** — Intermediate order items table; checked for margin percentage outliers

---

## Outputs

**Target: Redshift quality_log table** (implied by documentation; not shown in code)
- **quality_log** — Audit log containing one row per check execution with pass/fail status, actual vs. expected values, severity level, and error messages (if applicable). Consumed by:
  - Alerting systems (Slack, PagerDuty, email) for critical failures
  - Data quality dashboards and SLO tracking
  - Post-incident root cause analysis and trend analysis
  - Airflow task dependencies (downstream tasks may skip if critical checks fail)

**Console Output**
- Real-time check results printed to stdout/logs for immediate visibility during DAG execution

---

## Key Business Logic

### 1. **Order Volume Validation** (`orders_not_empty`)
- **Logic:** Counts orders from yesterday; fails if fewer than 100 orders exist
- **Why:** Detects pipeline failures, upstream data ingestion issues, or genuine business anomalies (e.g., system outage). A sudden drop in order volume is a leading indicator of data pipeline problems
- **Severity:** Critical — blocks downstream reporting if orders are missing

### 2. **Revenue Null Check** (`orders_no_null_revenue`)
- **Logic:** Counts orders with NULL gross_revenue in the last 3 days; fails if any exist
- **Why:** Revenue is a core business metric; NULL values indicate ETL transformation failures (missing joins, failed calculations, or data type mismatches). This is a hard constraint—revenue must always be populated
- **Severity:** Critical — NULL revenue breaks financial reporting and reconciliation

### 3. **Revenue Range Validation** (`orders_revenue_range`)
- **Logic:** Counts orders with negative revenue or revenue exceeding $50,000; fails if more than 0 exist
- **Why:** Detects data entry errors, calculation bugs, or fraudulent transactions. Negative revenue suggests refund logic errors; $50K+ suggests either legitimate high-value orders or data corruption. Threshold is configurable based on business rules
- **Severity:** Warning — allows investigation before escalation

### 4. **Customer Dimension Uniqueness** (`customers_unique`)
- **Logic:** Compares total row count to distinct customer_id count; fails if duplicates exist
- **Why:** Dimension tables must have one row per business entity. Duplicates indicate ETL SCD (Slowly Changing Dimension) logic failures, causing incorrect joins and inflated customer counts in downstream analytics
- **Severity:** Critical — corrupts all customer-level aggregations

### 5. **Product Cost Validation** (`products_have_cost`)
- **Logic:** Counts active products with NULL or zero/negative unit_cost; fails if any exist
- **Why:** Cost is required for margin calculations and profitability analysis. Missing costs break financial reporting and inventory valuation. Only checks active products (inactive products may legitimately lack costs)
- **Severity:** Warning — impacts margin calculations but doesn't block core operations

### 6. **Daily Revenue Freshness** (`daily_revenue_freshness`)
- **Logic:** Calculates days between max revenue_date and today; fails if staleness exceeds 2 days
- **Why:** Detects delayed or failed aggregation jobs. Revenue reporting must be near real-time for business decision-making. A 2-day lag is acceptable; beyond that suggests the aggregation pipeline is broken
- **Severity:** Critical — stale data is unusable for operational decisions

### 7. **Session Event Count Validation** (`sessions_event_count`)
- **Logic:** Counts sessions with event_count ≤ 0; fails if any exist
- **Why:** A session must contain at least one event by definition. Zero or negative counts indicate ETL aggregation errors or data corruption in the event stream
- **Severity:** Warning — impacts session-level analytics but doesn't block core metrics

### 8. **Margin Percentage Sanity Check** (`margin_sanity`)
- **Logic:** Counts order items with margin_pct < -50% or > 99%; fails if more than 10 exist
- **Why:** Extreme margins suggest calculation errors (e.g., cost > price, or division by zero). Allows up to 10 outliers (legitimate edge cases like loss leaders or data entry errors) before flagging
- **Severity:** Warning — outliers are expected but excessive counts indicate systematic issues

---

## Column Descriptions

**Output columns written to quality_log table:**

| Column | Type | Description | Example |
|--------|------|-------------|---------|
| `check_name` | VARCHAR | Unique identifier for the check | `orders_not_empty` |
| `table` | VARCHAR | Primary table(s) being validated | `marts.fct_orders` |
| `description` | VARCHAR | Human-readable business rule being tested | `Yesterday should have at least 100 orders` |
| `severity` | VARCHAR | Alert priority level: `critical` or `warning` | `critical` |
| `expected` | VARCHAR | Expected condition in operator + threshold format | `>= 100` |
| `actual` | NUMERIC | Actual value returned by the check query | `87` or `NULL` (if query failed) |
| `passed` | BOOLEAN | Whether the check passed (TRUE) or failed (FALSE) | `false` |
| `error` | VARCHAR | Exception message if query execution failed | `relation "marts.fct_orders" does not exist` |
| `run_at` | TIMESTAMP | ISO 8601 UTC timestamp of check execution | `2024-01-15T14:32:45.123456+00:00` |

---

## Data Quality & Edge Cases

### Null Handling
- **Query-level NULLs:** If a check query returns NULL (e.g., `MAX()` on empty table), `actual_value` is set to `None` and the check fails. This is intentional—NULL results indicate data absence or aggregation failures
- **Missing tables:** If a table doesn't exist, `psycopg2` raises an exception, caught and logged with `error` field populated; check marked as failed
- **Empty result sets:** `cursor.fetchone()[0]` will raise an IndexError if the query returns no rows; this is caught and logged as an error

### Operator Evaluation Logic
- **Supported operators:** `>=`, `<=`, `==`, `>`, `<` (case-sensitive)
- **Type coercion:** Assumes query results are numeric; string comparisons will fail silently or raise TypeError
- **Edge case:** `==` operator is exact equality; floating-point comparisons may fail due to precision (e.g., `0.0 == 0` works, but `0.1 + 0.2 == 0.3` may not)

### Assumptions About Upstream Data
1. **Table existence:** All referenced tables exist and are accessible by `REDSHIFT_USER`
2. **Column existence:** All columns referenced in check queries exist and have expected data types
3. **Date functions:** Assumes Redshift date functions (`CURRENT_DATE`, `DATEDIFF`) work as expected
4. **Timezone handling:** Assumes all timestamps are in UTC; `CURRENT_DATE` is evaluated server-side in Redshift's configured timezone
5. **No concurrent modifications:** Assumes tables are not being actively written to during check execution (could cause inconsistent results)

### What Could Break
- **Schema changes:** If columns are renamed/dropped or tables are dropped, queries fail with "column does not exist" or "relation does not exist" errors
- **Data type changes:** If a column changes from numeric to string, the comparison operators fail
- **Threshold miscalibration:** If business volume changes (e.g., seasonal spike), hardcoded thresholds (e.g., 100 orders) may trigger false positives
- **Timezone mismatches:** If Redshift cluster timezone differs from UTC, `CURRENT_DATE` may be off by a day
- **Stale credentials:** If `REDSHIFT_PASS` expires or is rotated, connection fails
- **Network issues:** If Redshift is unreachable, connection times out (no retry logic in current code)

---

## Performance Notes

### Query Execution Strategy
- **Sequential execution:** Checks run one-by-one in a single connection; no parallelization
- **Scan types:** Most checks perform full table scans (no WHERE clause optimization for large tables)
  - `orders_not_empty`: Scans `fct_orders` filtered by `order_date = CURRENT_DATE - 1` (should use partition pruning if table is partitioned by date)
  - `customers_unique`: Full scan of `dim_customers` with `COUNT(DISTINCT)` aggregation (expensive on large dimensions)
  - `margin_sanity`: Full scan of `int_order_items` with range filter (no index hint)

### Optimization Opportunities
- **Partitioning:** If `fct_orders` is partitioned by `order_date`, queries should automatically prune to single partition (verify with EXPLAIN)
- **Indexes:** Adding indexes on frequently filtered columns (e.g., `order_date`, `product_status`, `margin_pct`) would improve scan performance
- **Materialized views:** For expensive aggregations (e.g., `COUNT(DISTINCT customer_id)`), consider pre-computing in a separate table
- **Parallelization:** Current code could be refactored to execute checks in parallel using `ThreadPoolExecutor` or async connections

### Estimated Runtime
- **Typical:** 5-15 seconds for 8 checks on a reasonably-sized warehouse (millions of rows)
- **Worst case:** 30-60 seconds if tables are very large (billions of rows) and Redshift is under load
- **Bottleneck:** The `customers_unique` check (COUNT DISTINCT) is likely the slowest

### Connection Management
- **Single connection:** All checks share one connection; if one query hangs, subsequent checks are blocked
- **No connection pooling:** Each macro invocation creates a new connection (acceptable for post-ETL use case)
- **No timeout:** Queries can hang indefinitely; consider adding `statement_timeout` parameter

---

## Dependencies

### Upstream
- **Airflow DAG:** This macro is invoked as a task in an Airflow DAG after ETL tasks complete
- **ETL pipeline:** All source tables (`marts.*`, `transforms.*`) must be populated by prior ETL jobs
  - `marts.fct_orders` — populated by order fact table load
  - `marts.dim_customers` — populated by customer dimension load
  - `marts.dim_products` — populated by product dimension load
  - `marts.fct_daily_revenue` — populated by daily revenue aggregation job
  - `transforms.int_customer_sessions` — populated by session aggregation job
  - `transforms.int_order_items` — populated by order items transformation job
- **Redshift cluster:** Must be running and accessible at `REDSHIFT_HOST:REDSHIFT_PORT`
- **Environment variables:** `REDSHIFT_HOST`, `REDSHIFT_PORT`, `REDSHIFT_DB`, `REDSHIFT_USER`, `REDSHIFT_PASS` must be set

### Downstream
- **Alerting system:** Failures trigger notifications (Slack, PagerDuty, email) — integration point not shown in code
- **quality_log table:** Results are inserted into a logging table (schema/table definition not provided; assumed to exist)
- **Airflow task dependencies:** Downstream Airflow tasks may be configured to skip or fail based on check results
- **Data quality dashboards:** BI tools query `quality_log` to display check history and trends
- **SLO monitoring:** Data SLOs are tracked using check results (e.g., "99% of checks pass daily")

### External
- **psycopg2 library:** Python PostgreSQL adapter (Redshift-compatible)
- **OS environment:** Relies on environment variables for configuration (no hardcoded credentials, but defaults are provided)

---

## Code Quality & Maintenance Notes

### Current Limitations
1. **No retry logic:** Failed connections or queries are not retried; single transient failure causes entire check run to fail
2. **No transaction management:** Each check is auto-committed; no rollback on failure
3. **Incomplete code:** The `run_checks()` function is truncated; the error handling block and result insertion logic are missing
4. **Hardcoded thresholds:** Business rules are embedded in code; changes require code deployment (consider externalizing to config table)
5. **No logging framework:** Uses `print()` instead of structured logging (e.g., Python `logging` module)
6. **No metrics export:** Results are not exported to monitoring systems (Prometheus, CloudWatch, Datadog)

### Recommended Enhancements
- Add exponential backoff retry logic for transient failures
- Implement structured logging with log levels (DEBUG, INFO, WARNING, ERROR)
- Externalize check definitions to a configuration table or YAML file
- Add check execution timing and performance metrics
- Implement parallel check execution for faster runtime
- Add connection pooling and statement timeouts
- Export metrics to monitoring systems for alerting and dashboarding
- Add data lineage tracking (which upstream tables affected this check)