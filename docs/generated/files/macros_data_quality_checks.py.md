# macros/data_quality_checks.py

## Component Overview
- **Layer:** Utilities — Reusable scripts, macros, and helper functions
- **Type:** Python macro / Post-ETL validation script
- **Schedule:** Triggered after each ETL DAG completion (Airflow-orchestrated)
- **Owner:** Data Engineering (inferred from Airflow integration and warehouse access)

---

## Purpose

This macro executes a suite of automated data quality checks against the Redshift analytics warehouse immediately after ETL pipelines complete. It validates that transformed data meets business requirements (row counts, null constraints, value ranges, freshness, uniqueness) and logs all results to a centralized quality audit table. Failures trigger alerts to notify data engineers and analysts of data integrity issues before downstream consumers access potentially corrupted datasets.

---

## Inputs

**Data Sources (Redshift tables queried):**

- **marts.fct_orders** — Fact table of customer orders; checked for daily volume, null revenue values, and revenue outliers to ensure transactional completeness and data sanity.
- **marts.dim_customers** — Customer dimension; checked for duplicate customer_ids to ensure referential integrity and dimensional consistency.
- **marts.dim_products** — Product dimension; checked for missing or invalid unit costs on active products to ensure pricing data completeness.
- **marts.fct_daily_revenue** — Daily aggregated revenue fact table; checked for freshness to ensure reporting datasets are current within acceptable latency windows.
- **transforms.int_customer_sessions** — Intermediate sessions table; checked for valid event counts to ensure session-level aggregations are non-empty.
- **transforms.int_order_items** — Intermediate order items table; checked for extreme margin percentages to detect calculation errors or data anomalies.

**Configuration Inputs (environment variables):**

- `REDSHIFT_HOST`, `REDSHIFT_PORT`, `REDSHIFT_DB`, `REDSHIFT_USER`, `REDSHIFT_PASS` — Warehouse connection credentials (sourced from secure environment or secrets manager).

---

## Outputs

**Target Table:**

- **quality_log** (implied, referenced in docstring) — Centralized audit table containing one row per check execution with:
  - Check metadata (name, table, description, severity level)
  - Expected vs. actual results (threshold, operator, actual value)
  - Pass/fail status and execution timestamp
  - Error messages if check execution failed
  - Used by monitoring dashboards, alerting systems, and data governance workflows to track data quality trends and incident history.

**Console Output:**

- Formatted print statements showing pass/fail status for each check (used for Airflow task logs and real-time monitoring).

**Alert Triggers (implicit):**

- Critical-severity failures should trigger PagerDuty/Slack notifications to on-call data engineers.
- Warning-severity failures should be logged for daily review.

---

## Key Business Logic

### Check Execution Framework

1. **Connection Management:** Establishes a single persistent Redshift connection, executes all checks sequentially, and handles connection cleanup.
   - *Why:* Minimizes connection overhead and ensures consistent transaction isolation during validation.

2. **Check Evaluation Loop:** For each check definition:
   - Executes the check's SQL query against the warehouse
   - Extracts the single numeric result
   - Compares actual value against threshold using the specified operator
   - Records pass/fail status with full context (expected, actual, timestamp)
   - *Why:* Decouples check logic from evaluation logic, enabling reusable operator framework.

3. **Error Handling:** Wraps each check in try-except to capture SQL execution failures (e.g., table not found, permission denied) without halting the entire validation run.
   - *Why:* Ensures partial failures don't prevent other checks from running; allows investigation of infrastructure vs. data issues.

### Individual Check Definitions

| Check Name | Business Rule | Rationale |
|---|---|---|
| **orders_not_empty** | Yesterday's orders ≥ 100 | Detects ETL pipeline failures or data ingestion gaps; critical for daily reporting SLAs. |
| **orders_no_null_revenue** | Zero NULL gross_revenue in last 3 days | Ensures pricing/revenue calculations completed successfully; NULL values break financial reporting. |
| **orders_revenue_range** | No negative or >$50k orders | Detects calculation errors, data entry mistakes, or fraud; extreme values indicate upstream transformation bugs. |
| **customers_unique** | No duplicate customer_ids in dimension | Enforces dimensional integrity; duplicates cause incorrect joins and inflated customer counts in analytics. |
| **products_have_cost** | Active products have valid unit_cost | Ensures margin calculations are possible; missing costs break profitability analysis. |
| **daily_revenue_freshness** | Revenue data ≤ 2 days stale | Guarantees reporting freshness; stale data indicates ETL delays or pipeline failures. |
| **sessions_event_count** | All sessions have ≥ 1 event | Detects aggregation errors; zero-event sessions indicate incomplete data or calculation bugs. |
| **margin_sanity** | ≤ 10 items with extreme margins (-50% to 99%) | Allows small number of edge cases but flags systematic calculation errors; thresholds based on historical norms. |

### Operator Framework

The `evaluate_check()` function supports flexible comparison operators (`>=`, `<=`, `==`, `>`, `<`), enabling:
- **Count-based checks** (e.g., `>= 100` orders) using `>=` operator
- **Null/uniqueness checks** (e.g., `== 0` duplicates) using `==` operator
- **Freshness checks** (e.g., `<= 2` days stale) using `<=` operator
- **Outlier detection** (e.g., `<= 10` extreme margins) using `<=` operator

---

## Column Descriptions

**Output columns in quality_log table:**

| Column | Type | Description | Example |
|--------|------|-------------|---------|
| **check_name** | VARCHAR | Unique identifier for the check | `orders_not_empty` |
| **table** | VARCHAR | Primary table being validated | `marts.fct_orders` |
| **description** | VARCHAR | Human-readable business rule | `Yesterday should have at least 100 orders` |
| **severity** | VARCHAR | Alert priority level: `critical` or `warning` | `critical` |
| **expected** | VARCHAR | Threshold and operator in readable format | `>= 100` |
| **actual** | NUMERIC | Observed value from the check query | `145` or `NULL` (if query failed) |
| **passed** | BOOLEAN | Whether actual satisfies expected condition | `true` or `false` |
| **run_at** | TIMESTAMP | UTC timestamp when check executed | `2024-01-15T14:32:18.123456+00:00` |
| **error** | VARCHAR | Exception message if check failed to execute | `relation "marts.fct_orders" does not exist` |

---

## Data Quality & Edge Cases

### Null Handling

- **Query Results:** If a check query returns `NULL` (e.g., `MAX()` on empty table), `cursor.fetchone()[0]` returns `None`, which is stored in the `actual` column and causes the check to fail (since `None` will not satisfy any numeric comparison).
  - *Risk:* Ambiguity between "check failed" and "data is missing." Consider explicit NULL handling in check queries (e.g., `COALESCE(MAX(revenue_date), CURRENT_DATE - 999)`).

- **Missing Columns:** If a check references a non-existent column, the exception is caught and logged with `error` field populated; check marked as failed.

### Deduplication & Uniqueness

- **customers_unique check:** Uses `COUNT(*) - COUNT(DISTINCT customer_id)` to detect duplicates. This approach:
  - Counts total rows minus distinct customer IDs; result > 0 indicates duplicates.
  - Does not identify *which* customers are duplicated (only that duplicates exist).
  - Assumes `customer_id` is the natural key; if composite keys exist, this check is insufficient.

### Assumptions About Upstream Data

1. **Date Arithmetic:** Checks assume `CURRENT_DATE` and `CURRENT_DATE - 1` are valid in Redshift (they are, but timezone handling depends on warehouse configuration).
   - *Risk:* If warehouse is in UTC but business logic expects US/Eastern, freshness checks may incorrectly flag data as stale.

2. **Table Existence:** No pre-flight checks verify that tables exist before running checks. If a table is dropped or renamed, the check fails silently (caught in exception handler).
   - *Risk:* Silent failures may not trigger alerts if error handling is not properly configured downstream.

3. **Data Types:** Checks assume numeric columns are properly typed (e.g., `gross_revenue` is NUMERIC, not VARCHAR). If a column is cast incorrectly upstream, comparisons may fail or produce unexpected results.
   - *Risk:* `WHERE gross_revenue < 0` will fail if `gross_revenue` is a string.

4. **Temporal Consistency:** Checks using `CURRENT_DATE - 1` assume the ETL runs daily and data is available for yesterday. If ETL runs on a different schedule, checks may incorrectly fail.
   - *Risk:* Weekend/holiday runs may have zero orders, triggering false failures.

### What Could Break

| Scenario | Impact | Mitigation |
|----------|--------|-----------|
| Table renamed or dropped | Check fails with "relation does not exist" error; logged but may not alert | Add pre-flight table existence checks; monitor error logs |
| Column renamed or removed | Check fails with "column does not exist" error | Version control check definitions; add schema validation |
| Upstream ETL delays | Freshness check fails; revenue data is stale | Adjust freshness thresholds; add retry logic in Airflow |
| Data type changes (e.g., VARCHAR instead of NUMERIC) | Comparisons fail or produce unexpected results | Add data type validation in check queries |
| Extreme but valid data (e.g., $50k+ order) | Outlier check flags legitimate data as anomalous | Periodically review thresholds; add business context to alerts |
| Connection credentials expire | All checks fail with authentication error | Implement credential rotation; add connection retry logic |

---

## Performance Notes

### Query Patterns & Efficiency

1. **Full Table Scans:** Most checks perform full table scans (no WHERE clause filtering or indexed lookups):
   - `SELECT COUNT(*) FROM marts.fct_orders` — scans entire fact table
   - `SELECT COUNT(*) - COUNT(DISTINCT customer_id) FROM marts.dim_customers` — scans entire dimension
   - *Impact:* On large tables (millions of rows), these scans can take 10-30 seconds each. With 8 checks, total runtime could be 2-5 minutes.
   - *Mitigation:* Add date filtering where possible (e.g., `WHERE order_date >= CURRENT_DATE - 3` for recent data only). Consider materialized views or pre-aggregated check tables.

2. **Aggregation Functions:** Checks use `COUNT()`, `COUNT(DISTINCT)`, `MAX()`, `DATEDIFF()` — all efficient in Redshift but still require full scans.
   - *Impact:* Minimal additional cost beyond the scan itself.

3. **Sequential Execution:** Checks run one-by-one in a single connection, not in parallel.
   - *Impact:* Total runtime is sum of individual check times. With 8 checks × 5 seconds average = 40 seconds.
   - *Optimization:* Could parallelize checks using thread pool or async connections, but adds complexity.

### Partitioning & Distribution

- **Redshift Distribution Keys:** Checks do not specify distribution keys, so Redshift uses default distribution. If tables are distributed on `customer_id` or `order_id`, full table scans still require all nodes to participate.
  - *Implication:* No performance benefit from distribution keys for these checks; all nodes must scan their local data.

- **Redshift Sort Keys:** If tables have sort keys (e.g., `order_date`), checks with date filters (e.g., `WHERE order_date >= CURRENT_DATE - 3`) can use zone maps to skip blocks, reducing scan time.
  - *Implication:* Checks with date filters are faster than those without; consider adding date filters to all checks where possible.

### Connection Pooling

- **Single Connection:** All checks share one connection, avoiding connection overhead but serializing queries.
  - *Alternative:* Could use connection pooling (e.g., `psycopg2.pool.SimpleConnectionPool`) to parallelize checks, but adds complexity and may exceed connection limits.

### Recommended Optimizations

1. **Add date filtering** to all checks (e.g., `WHERE order_date >= CURRENT_DATE - 7`) to reduce scan scope.
2. **Materialize check queries** into a pre-aggregated table updated hourly, then query that table instead of raw data.
3. **Parallelize checks** using thread pool or async connections to reduce total runtime.
4. **Add query timeouts** (e.g., 30 seconds) to prevent runaway queries from blocking the entire validation run.

---

## Dependencies

### Upstream Dependencies

**Components that must complete before this macro runs:**

- **All ETL DAGs** (inferred from docstring: "Called by Airflow after the ETL DAG completes")
  - Specifically: data ingestion pipelines that populate `stg_*` tables, transformation pipelines that populate `transforms.int_*` tables, and mart pipelines that populate `marts.fct_*` and `marts.dim_*` tables.
  - *Why:* Quality checks validate the output of these pipelines; if they haven't run, there's no data to check.

- **Redshift Warehouse** must be running and accessible
  - *Why:* All checks query Redshift; if the warehouse is paused or unreachable, all checks fail.

- **quality_log table** must exist and be writable
  - *Why:* Results are written to this table; if it doesn't exist, the macro fails when attempting to insert results.

### Downstream Dependencies

**Components that depend on this macro's output:**

- **Alerting System** (e.g., PagerDuty, Slack, email)
  - Consumes `quality_log` table or check results to trigger notifications on critical failures.
  - *Why:* Data engineers need real-time alerts when data quality issues occur.

- **Data Quality Dashboard** (e.g., Tableau, Looker, Grafana)
  - Queries `quality_log` table to visualize check history, pass rates, and failure trends.
  - *Why:* Stakeholders need visibility into data quality over time.

- **Airflow DAG** (the orchestrator)
  - Receives exit code or status from this macro to determine whether to mark the DAG as successful or failed.
  - *Why:* If critical checks fail, the DAG should fail to prevent downstream consumers from using corrupted data.

- **Data Consumers** (analysts, BI tools, ML pipelines)
  - Implicitly depend on this macro; if it passes, they can trust the data; if it fails, they should be notified not to use the data.
  - *Why:* Prevents propagation of data quality issues downstream.

### External Dependencies

- **Environment Variables:** `REDSHIFT_HOST`, `REDSHIFT_PORT`, `REDSHIFT_DB`, `REDSHIFT_USER`, `REDSHIFT_PASS`
  - *Source:* Airflow secrets manager, AWS Secrets Manager, or environment configuration.
  - *Risk:* If credentials are incorrect or expired, all checks fail with authentication errors.

- **Python Libraries:**
  - `psycopg2` — Redshift/PostgreSQL driver; must be installed in Airflow environment.
  - `os`, `json`, `datetime` — Standard library; always available.

- **Redshift IAM Permissions:** The `etl_user` account must have `SELECT` permissions on all checked tables.
  - *Risk:* If permissions are revoked, checks fail with "permission denied" errors.

---

## Implementation Notes & Recommendations

### Current Limitations

1. **No Result Persistence:** The macro prints results to console but does not explicitly insert them into `quality_log` table (code is truncated, but this is implied).
   - *Recommendation:* Add explicit INSERT statement to persist results for audit trail and downstream alerting.

2. **No Retry Logic:** If a check query times out or fails, it's marked as failed immediately without retry.
   - *Recommendation:* Add exponential backoff retry logic for transient failures (e.g., connection timeouts).

3. **No Parallel Execution:** Checks run sequentially, limiting throughput.
   - *Recommendation:* Use `concurrent.futures.ThreadPoolExecutor` to parallelize checks and reduce total runtime.

4. **Hardcoded Thresholds:** Check thresholds are embedded in code, requiring code changes to adjust sensitivity.
   - *Recommendation:* Move thresholds to a configuration table or YAML file for easier tuning without redeployment.

5. **No Context on Failures:** When a check fails, there's no automatic investigation (e.g., "which customers are duplicated?").
   - *Recommendation:* Add diagnostic queries that run on failure to provide root cause information.

### Suggested Enhancements

```python
# Example: Add result persistence
def persist_results(results):
    """Insert check results into quality_log table."""
    conn = get_connection()
    cursor = conn.cursor()
    for result in results:
        cursor.execute("""
            INSERT INTO quality_log 
            (check_name, table, description, severity, expected, actual, passed, run_at, error)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
        """, (
            result['check_name'],
            result['table'],
            result['description'],
            result['severity'],
            result['expected'],
            result['actual'],
            result['passed'],
            result['run_at'],
            result.get('error'),
        ))
    conn.commit()
    cursor.close()
    conn.close()

# Example: Add alerting
def trigger_alerts(results):
    """Send alerts for critical failures."""
    critical_failures = [r for r in results if r['severity'] == 'critical' and not r['passed']]
    if critical_failures:
        message = f"Data Quality Alert: {len(critical_failures)} critical checks failed\n"
        for failure in critical_failures:
            message += f"  - {failure['check_name']}: {failure['description']}\n"
        # Send to Slack, PagerDuty, etc.
        send_slack_message(message)
```