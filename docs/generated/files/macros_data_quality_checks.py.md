# macros/data_quality_checks.py

## Component Overview
- **Layer:** Utilities — Reusable scripts, macros, and helper functions
- **Type:** Python macro / monitoring script
- **Schedule:** Post-ETL execution (triggered by Airflow DAG completion)
- **Owner:** Data Engineering / Data Quality team

---

## Purpose

This macro executes a suite of automated data quality checks against the Redshift analytics warehouse immediately after each ETL run completes. It validates that transformed data meets business expectations (row counts, null constraints, value ranges, freshness, uniqueness) and logs all results to a centralized quality audit table. When checks fail, the script flags them by severity level to trigger downstream alerting mechanisms, enabling the data team to detect and respond to pipeline failures or data anomalies before they propagate to analytics consumers.

---

## Inputs

This script does not consume external data files or tables as inputs. Instead, it **queries** the following Redshift tables to validate their contents:

| Table | Purpose of Query |
|-------|------------------|
| **marts.fct_orders** | Validates row volume, null constraints, and value ranges on daily order facts (revenue, order dates) |
| **marts.dim_customers** | Checks for duplicate customer_ids in the customer dimension |
| **marts.dim_products** | Validates that active products have non-null, positive unit costs |
| **marts.fct_daily_revenue** | Monitors data freshness by checking the staleness of the most recent revenue_date |
| **transforms.int_customer_sessions** | Validates that all sessions have at least one associated event |
| **transforms.int_order_items** | Checks for anomalous margin percentages that may indicate calculation errors |

---

## Outputs

| Output | Type | Description | Consumers |
|--------|------|-------------|-----------|
| **quality_log** (implied) | Redshift table | Centralized audit log containing check results, actual vs. expected values, pass/fail status, timestamps, and error messages. Each row represents one check execution. | Data quality dashboards, alerting systems, post-incident analysis, SLA tracking |
| **Console/Log output** | Stdout | Human-readable pass/fail status for each check printed to Airflow task logs for real-time monitoring | Data engineers, Airflow UI, log aggregation systems |
| **Alert triggers** (implied) | Event/notification | Failures with `severity: critical` trigger immediate alerts; `severity: warning` may trigger digest alerts or be logged for review | On-call data engineers, Slack/PagerDuty, incident management systems |

---

## Key Business Logic

### 1. **Check Definition Framework**
Each check is a declarative dictionary containing:
- **SQL query** — executes against Redshift and returns a single numeric value
- **Threshold + operator** — defines the pass/fail boundary (e.g., `>= 100`, `== 0`, `<= 2`)
- **Severity level** — categorizes impact (`critical` = immediate action required; `warning` = monitor/investigate)
- **Description** — human-readable business rule for documentation and alerts

This design allows new checks to be added without modifying core logic.

### 2. **Volume & Completeness Checks**
```
orders_not_empty: COUNT(*) >= 100 for yesterday's orders
orders_no_null_revenue: COUNT(NULL gross_revenue) == 0 for last 3 days
```
**Why:** Ensures the ETL pipeline is producing expected data volume and that critical financial fields are populated. A drop below 100 orders or presence of null revenue indicates upstream ingestion or transformation failure.

### 3. **Data Integrity Checks**
```
customers_unique: COUNT(*) - COUNT(DISTINCT customer_id) == 0
products_have_cost: COUNT(NULL/invalid unit_cost for Active products) == 0
```
**Why:** Enforces uniqueness constraints and required field validation. Duplicate customer IDs or missing costs would corrupt downstream analytics and reporting.

### 4. **Value Range & Sanity Checks**
```
orders_revenue_range: COUNT(negative or > $50k revenue) == 0
margin_sanity: COUNT(margin_pct < -50% or > 99%) <= 10
```
**Why:** Detects data anomalies that pass null checks but violate business logic (e.g., negative revenue, impossible margins). Thresholds allow small numbers of edge cases while flagging systematic problems.

### 5. **Freshness Checks**
```
daily_revenue_freshness: DATEDIFF(day, MAX(revenue_date), CURRENT_DATE) <= 2
```
**Why:** Ensures downstream consumers receive timely data. A 2-day lag threshold allows for batch processing delays while catching stalled pipelines.

### 6. **Evaluation & Result Logging**
```python
evaluate_check(actual_value, threshold, operator)
```
Compares the query result against the threshold using the specified operator (`>=`, `<=`, `==`, `>`, `<`). Results are structured as dictionaries containing:
- Check metadata (name, table, description, severity)
- Expected vs. actual values
- Pass/fail boolean
- Execution timestamp (UTC ISO format)
- Error messages (if query execution failed)

This structured format enables programmatic alerting and audit trail analysis.

---

## Column Descriptions

### Output Result Dictionary Structure

| Field | Type | Description | Example |
|-------|------|-------------|---------|
| **check_name** | string | Unique identifier for the check | `"orders_not_empty"` |
| **table** | string | Primary Redshift table being validated | `"marts.fct_orders"` |
| **description** | string | Business rule in plain English | `"Yesterday should have at least 100 orders"` |
| **severity** | string | Impact level: `"critical"` or `"warning"` | `"critical"` |
| **expected** | string | Human-readable threshold expression | `">= 100"` |
| **actual** | int/float/null | Query result value | `247` or `null` (if query failed) |
| **passed** | boolean | Whether actual satisfies expected condition | `true` or `false` |
| **run_at** | string | ISO 8601 UTC timestamp of check execution | `"2024-01-15T14:32:18.456789+00:00"` |
| **error** | string (optional) | Exception message if query execution failed | `"relation 'marts.fct_orders' does not exist"` |

---

## Data Quality & Edge Cases

### Null Handling
- **Query failures** (e.g., table doesn't exist, permission denied) are caught and logged with `passed: false` and an error message. The check does not halt execution; all checks run regardless of individual failures.
- **NULL query results** (e.g., `MAX()` on empty table) are stored as `actual: null` and will fail most comparisons, correctly flagging data absence.
- **NULL in threshold comparisons** — the `evaluate_check()` function does not explicitly handle null comparisons; a null actual value will fail `>=`, `<=`, `==` operators, which is the desired behavior.

### Deduplication Strategy
- No deduplication is performed; checks query raw table data. The `customers_unique` check explicitly detects duplicates by comparing `COUNT(*)` to `COUNT(DISTINCT customer_id)`.
- If a table has been loaded multiple times without truncation, duplicate rows will be detected and flagged as a failure.

### Assumptions About Upstream Data
1. **Table existence** — assumes all referenced tables (`marts.fct_orders`, `marts.dim_customers`, etc.) exist and are readable by the `etl_user` role.
2. **Column existence** — assumes all referenced columns (`order_date`, `gross_revenue`, `customer_id`, `unit_cost`, `revenue_date`, `event_count`, `margin_pct`) exist and contain expected data types.
3. **Date functions** — assumes Redshift date functions (`CURRENT_DATE`, `DATEDIFF`, `MAX()`) behave as documented.
4. **Single-row results** — all SQL queries are designed to return exactly one row with one column; multi-row results will only use the first row (`fetchone()[0]`).
5. **Timezone consistency** — assumes `CURRENT_DATE` in Redshift is evaluated in UTC or a consistent timezone; if Redshift is in a different timezone, freshness checks may be off by one day.

### What Could Break

| Scenario | Impact | Mitigation |
|----------|--------|-----------|
| **Table renamed or dropped** | Query fails with "relation does not exist"; check marked as failed with error message | Error is logged; alerting system should escalate query errors separately from data failures |
| **Column renamed or dropped** | Query fails with "column does not exist"; check marked as failed | Same as above |
| **Redshift cluster unavailable** | Connection fails in `get_connection()`; entire script fails (no try-catch at top level) | **Risk:** Script crashes without logging results. **Recommendation:** Wrap `run_checks()` call in try-catch at caller level (Airflow task) |
| **Permission revoked on table** | Query fails with "permission denied"; check marked as failed | Error is logged; alerting system should distinguish permission errors from data errors |
| **Upstream ETL doesn't run** | Tables are stale; freshness check fails; volume checks may fail if no new data loaded | Intended behavior; alerts notify team of upstream failure |
| **Timezone mismatch** | `CURRENT_DATE` in Redshift differs from expectation; freshness check off by one day | **Risk:** False positives/negatives. **Recommendation:** Use explicit timezone conversion or document assumed timezone |
| **Operator typo in check definition** | `evaluate_check()` raises `ValueError`; check marked as failed | Error is logged; configuration should be code-reviewed |

---

## Performance Notes

### Query Patterns & Efficiency

| Check | Query Pattern | Performance Implications |
|-------|---------------|--------------------------|
| **orders_not_empty** | `COUNT(*) WHERE order_date = CURRENT_DATE - 1` | **Efficient if partitioned on order_date.** Redshift can prune partitions and use aggregate pushdown. Estimated cost: milliseconds if partition exists. |
| **orders_no_null_revenue** | `COUNT(*) WHERE gross_revenue IS NULL AND order_date >= CURRENT_DATE - 3` | **Moderate cost.** Scans 3 days of data; benefits from order_date partitioning. If `fct_orders` is large (billions of rows), this could take seconds. |
| **orders_revenue_range** | `COUNT(*) WHERE gross_revenue < 0 OR gross_revenue > 50000` | **Full table scan or index scan.** No date filter; scans all historical orders. **Risk:** Could be slow on very large tables. **Recommendation:** Add date filter (e.g., `order_date >= CURRENT_DATE - 30`) to limit scope. |
| **customers_unique** | `COUNT(*) - COUNT(DISTINCT customer_id)` | **Full table scan.** Requires two aggregations over entire `dim_customers` table. If dimension is large (millions of rows), this could take seconds. Acceptable for post-ETL validation. |
| **products_have_cost** | `COUNT(*) WHERE unit_cost IS NULL OR unit_cost <= 0 AND product_status = 'Active'` | **Efficient.** Dimensions are typically small (thousands of rows). Negligible cost. |
| **daily_revenue_freshness** | `SELECT DATEDIFF(day, MAX(revenue_date), CURRENT_DATE)` | **Efficient.** Single aggregate function; Redshift can use index on `revenue_date` if available. Milliseconds. |
| **sessions_event_count** | `COUNT(*) WHERE event_count <= 0` | **Moderate cost.** Depends on size of `transforms.int_customer_sessions`. If intermediate table is large, could take seconds. |
| **margin_sanity** | `COUNT(*) WHERE margin_pct < -50 OR margin_pct > 99` | **Full table scan.** No date filter; scans all historical order items. **Risk:** Could be slow. **Recommendation:** Add date filter. |

### Partitioning & Distribution Keys
- **Assumption:** `fct_orders` and `fct_daily_revenue` are partitioned on date columns (`order_date`, `revenue_date`) to enable partition pruning.
- **Assumption:** `dim_customers` and `dim_products` are small dimensions, likely distributed on primary key (`customer_id`, `product_id`).
- **Risk:** If tables are not partitioned/distributed as assumed, queries will perform full table scans and could be slow.

### Execution Time Estimate
- **Total runtime:** 5–30 seconds (depending on table sizes and Redshift cluster load).
- **Bottleneck:** `orders_revenue_range` and `margin_sanity` checks (full table scans without date filters).
- **Recommendation:** Add date filters to limit scope, or run checks in parallel (current implementation is sequential).

### Connection & Cursor Management
- **Single connection** is created and reused for all checks.
- **No connection pooling** — acceptable for post-ETL validation (runs once per day), but not suitable for high-frequency monitoring.
- **No explicit cursor close** — cursor is not closed after use. **Risk:** Resource leak if script runs frequently. **Recommendation:** Add `cursor.close()` and `conn.close()` in a finally block.

---

## Dependencies

### Upstream Dependencies
| Component | Type | Why Required | Failure Impact |
|-----------|------|--------------|-----------------|
| **Redshift cluster** | Infrastructure | All checks query Redshift tables | Script fails if cluster is unavailable or unreachable |
| **ETL DAG (Airflow)** | Orchestration | This macro is triggered after ETL completes | Checks run against stale data if ETL fails upstream |
| **marts.fct_orders** | Table | Validated by 3 checks | If table doesn't exist or isn't populated, checks fail |
| **marts.dim_customers** | Table | Validated by 1 check | If table doesn't exist, uniqueness check fails |
| **marts.dim_products** | Table | Validated by 1 check | If table doesn't exist, cost validation check fails |
| **marts.fct_daily_revenue** | Table | Validated by 1 check | If table doesn't exist, freshness check fails |
| **transforms.int_customer_sessions** | Table | Validated by 1 check | If table doesn't exist, event count check fails |
| **transforms.int_order_items** | Table | Validated by 1 check | If table doesn't exist, margin check fails |
| **Environment variables** | Configuration | `REDSHIFT_HOST`, `REDSHIFT_PORT`, `REDSHIFT_DB`, `REDSHIFT_USER`, `REDSHIFT_PASS` | Script fails if credentials are missing or invalid |

### Downstream Dependencies
| Component | Type | How It Consumes Output | Failure Impact |
|-----------|------|------------------------|-----------------|
| **quality_log table** | Redshift table | Stores all check results for audit trail and SLA tracking | Historical record of data quality; enables trend analysis |
| **Alerting system** (Slack, PagerDuty, email) | Notification service | Triggered by `severity: critical` failures | Data team is notified of pipeline issues; enables rapid response |
| **Data quality dashboard** | BI/monitoring tool | Queries `quality_log` to display check history and trends | Stakeholders monitor data health; identifies systemic issues |
| **Incident management** | Process | Failed checks trigger incident creation or escalation | On-call engineer is paged; incident is tracked |
| **Airflow DAG** | Orchestration | Task status determines whether downstream tasks proceed | If checks fail, dependent tasks may be skipped or retried |

### External Dependencies
| System | Type | Purpose | Failure Impact |
|--------|------|---------|-----------------|
| **psycopg2 library** | Python package | Redshift connection driver | Script fails if library is not installed in Airflow environment |
| **Redshift IAM role / credentials** | AWS security | Authenticates `etl_user` to Redshift | Script fails if credentials are invalid or revoked |
| **Redshift security group** | AWS networking | Allows inbound connections on port 5439 | Script fails if network is blocked |

---

## Known Limitations & Recommendations

### Critical Issues

1. **No connection cleanup**
   - **Issue:** `cursor` and `conn` are never explicitly closed.
   - **Risk:** Resource leak if script runs frequently (e.g., every hour).
   - **Fix:** Add `finally` block to close resources:
     ```python
     try:
         cursor.execute(...)
     finally:
         cursor.close()
         conn.close()
     ```

2. **No top-level error handling**
   - **Issue:** If `get_connection()` fails, entire script crashes without logging results.
   - **Risk:** Airflow task fails; no quality results are recorded.
   - **Fix:** Wrap `run_checks()` in try-catch at caller level (Airflow task operator).

3. **Missing date filters on large table scans**
   - **Issue:** `orders_revenue_range` and `margin_sanity` checks scan all historical data.
   - **Risk:** Slow performance on large tables; could timeout.
   - **Fix:** Add date filters (e.g., `order_date >= CURRENT_DATE - 30`).

4. **No results persistence**
   - **Issue:** Results are printed to stdout but not written to `quality_log` table.
   - **Risk:** Results are lost; no audit trail.
   - **Fix:** Add code to insert results into `quality_log` table after checks complete.

5. **Timezone assumption**
   - **Issue:** `CURRENT_DATE` in Redshift may be in a different timezone than expected.
   - **Risk:** Freshness check off by one day; false positives/negatives.
   - **Fix:** Use explicit timezone conversion or document assumed timezone.

### Enhancements

- **Parallel execution:** Run checks in parallel threads to reduce total runtime.
- **Configurable checks:** Load check definitions from a config file or database instead of hardcoding.
- **Retry logic:** Retry failed queries (e.g., transient connection errors).
- **Metrics export:** Send check results to CloudWatch or Datadog for monitoring.
- **Threshold tuning:** Use historical data to auto-adjust thresholds based on trends.