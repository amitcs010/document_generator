# macros/data_quality_checks.py

## Component Overview
- **Layer:** Utilities — Reusable scripts, macros, and helper functions
- **Type:** Python macro / Post-ETL validation script
- **Schedule:** Triggered after each ETL DAG completion (Airflow-orchestrated)
- **Owner:** Data Engineering (inferred from documentation context)

---

## Purpose

This macro executes a suite of automated data quality checks against the Redshift analytics warehouse immediately following ETL pipeline runs. It validates that transformed data meets business-critical thresholds (row counts, null rates, value ranges, freshness) and logs all results to a centralized quality audit table. Failures trigger alerting mechanisms, enabling the data team to catch data anomalies before they propagate to downstream analytics and business intelligence systems.

---

## Inputs

### Source Tables (Read-Only Validation)
- **marts.fct_orders** — Fact table of transactional orders; checked for row volume, null revenue values, and revenue outliers to ensure data completeness and accuracy
- **marts.dim_customers** — Customer dimension; validated for duplicate customer_ids to maintain referential integrity
- **marts.dim_products** — Product dimension; checked for missing or invalid unit costs on active products to support margin calculations
- **marts.fct_daily_revenue** — Aggregated daily revenue fact table; validated for freshness to ensure reporting datasets are current
- **transforms.int_customer_sessions** — Intermediate session table; checked for valid event counts to catch incomplete session aggregations
- **transforms.int_order_items** — Intermediate order-item detail; validated for extreme margin percentages to detect calculation errors

### Configuration Inputs
- **Environment variables** — Redshift connection credentials (`REDSHIFT_HOST`, `REDSHIFT_PORT`, `REDSHIFT_DB`, `REDSHIFT_USER`, `REDSHIFT_PASS`)
- **CHECKS list** — Hardcoded quality check definitions (8 checks defined; extensible)

---

## Outputs

### Primary Output: quality_log Table
- **Destination:** `quality_log` table in Redshift (inferred; not explicitly shown in code but referenced in docstring)
- **Contents:** One row per check execution, containing:
  - Check metadata (name, table, description, severity level)
  - Expected vs. actual values
  - Pass/fail status
  - Execution timestamp
  - Error messages (if applicable)

### Secondary Outputs
- **Console logs** — Human-readable pass/fail status printed to stdout for Airflow task logs
- **Alert triggers** — Failures (especially `severity: "critical"`) likely trigger downstream alerting (Slack, PagerDuty, email) via Airflow operators

---

## Key Business Logic

### 1. **Volume & Freshness Validation**
- **orders_not_empty:** Ensures yesterday's order volume ≥ 100 orders
  - *Why:* Detects pipeline failures that result in zero or near-zero order ingestion; threshold of 100 is a business-defined minimum daily volume
- **daily_revenue_freshness:** Validates that daily revenue data is ≤ 2 days stale
  - *Why:* Ensures reporting dashboards reflect near-real-time business performance; staleness > 2 days indicates ETL delays or failures

### 2. **Data Integrity & Completeness**
- **orders_no_null_revenue:** Flags any orders from the last 3 days with NULL `gross_revenue`
  - *Why:* Revenue is a critical business metric; nulls indicate upstream data quality issues or transformation failures
  - *Scope:* 3-day lookback captures late-arriving data corrections
- **customers_unique:** Detects duplicate `customer_id` values in the customer dimension
  - *Why:* Dimension tables must have unique keys; duplicates break join logic and distort customer counts
- **products_have_cost:** Ensures active products have valid (non-null, positive) `unit_cost`
  - *Why:* Cost is required for margin calculations; missing costs produce invalid financial metrics

### 3. **Data Quality & Sanity Checks**
- **orders_revenue_range:** Flags orders with negative or suspiciously high (>$50,000) revenue
  - *Why:* Detects data entry errors, calculation bugs, or fraudulent transactions; thresholds are business-defined outlier boundaries
- **sessions_event_count:** Ensures all sessions have ≥ 1 event
  - *Why:* A session with zero events is logically invalid; indicates incomplete aggregation or bad data
- **margin_sanity:** Flags items with extreme margin percentages (< -50% or > 99%)
  - *Why:* Detects pricing or cost calculation errors; extreme margins are business anomalies
  - *Threshold:* Allows up to 10 extreme items (acknowledges rare edge cases) but flags if count exceeds this

### 4. **Evaluation Logic**
- **evaluate_check():** Compares actual metric against threshold using configurable operators (`>=`, `<=`, `==`, `>`, `<`)
  - Enables flexible rule definitions without code changes
  - Supports both "must be at least X" (e.g., row counts) and "must be exactly X" (e.g., nulls) patterns

---

## Column Descriptions

### Output Columns (quality_log table structure, inferred from results list)

| Column | Data Type | Description | Example Values |
|--------|-----------|-------------|-----------------|
| **check_name** | VARCHAR | Unique identifier for the check | `"orders_not_empty"`, `"customers_unique"` |
| **table** | VARCHAR | Schema-qualified table being validated | `"marts.fct_orders"`, `"transforms.int_customer_sessions"` |
| **description** | VARCHAR | Human-readable check purpose | `"Yesterday should have at least 100 orders"` |
| **severity** | VARCHAR | Impact level if check fails | `"critical"`, `"warning"` |
| **expected** | VARCHAR | Threshold condition in human-readable form | `">= 100"`, `"== 0"`, `"<= 2"` |
| **actual** | NUMERIC/NULL | Observed metric value from query | `245`, `0`, `NULL` (if query failed) |
| **passed** | BOOLEAN | Whether actual satisfies expected condition | `true`, `false` |
| **run_at** | TIMESTAMP | UTC timestamp of check execution | `"2024-01-15T14:32:47.123456+00:00"` |
| **error** | VARCHAR/NULL | Exception message if query failed | `"relation 'marts.fct_orders' does not exist"`, `NULL` (if successful) |

---

## Data Quality & Edge Cases

### Null Handling
- **Query-level nulls:** If a check query returns NULL (e.g., `MAX()` on empty table), `actual_value` is set to `None` and check fails
  - *Example:* `daily_revenue_freshness` returns NULL if `fct_daily_revenue` is empty; comparison `NULL <= 2` evaluates to False
- **Missing columns:** If a column referenced in a check doesn't exist, the query throws an exception; caught and logged with `passed: False` and error message
- **Incomplete data:** Checks use date filters (e.g., `order_date = CURRENT_DATE - 1`) to isolate recent data; assumes system date is accurate

### Deduplication Strategy
- **No deduplication in checks themselves** — checks validate that duplicates *don't exist* (e.g., `customers_unique` explicitly counts duplicates)
- **Assumption:** Upstream ETL is responsible for deduplication; this macro only detects failures

### Key Assumptions About Data
1. **System clock accuracy:** Checks rely on `CURRENT_DATE` and `CURRENT_DATE - 1`; assumes Redshift server time is synchronized
2. **Table existence:** Assumes all referenced tables exist; missing tables cause query failures (caught and logged)
3. **Column existence:** Assumes all referenced columns exist and have expected data types (e.g., `order_date` is DATE, `gross_revenue` is NUMERIC)
4. **Data freshness:** Assumes ETL completes before this macro runs; if ETL is delayed, freshness checks may fail even if pipeline is healthy
5. **Threshold appropriateness:** Assumes hardcoded thresholds (e.g., 100 orders/day, $50K max revenue) remain valid; no dynamic threshold adjustment

### What Could Break
- **Schema changes:** Renaming/dropping columns or tables breaks queries (e.g., if `gross_revenue` → `total_revenue`)
- **Data type changes:** If `order_date` changes from DATE to TIMESTAMP, date arithmetic may fail
- **Upstream delays:** If ETL runs late, freshness checks fail even though pipeline is functional
- **Threshold obsolescence:** Business volume growth may make 100 orders/day threshold too low; requires manual code update
- **Connection failures:** If Redshift is unreachable or credentials are invalid, all checks fail with connection error
- **Concurrent modifications:** If ETL is still running when checks execute, checks may see partial/inconsistent data

---

## Performance Notes

### Query Patterns & Efficiency
- **Simple aggregations:** Most checks use `COUNT()` or `COUNT(DISTINCT)` with optional `WHERE` filters
  - *Performance:* Fast on indexed columns; Redshift's columnar storage optimizes these operations
  - *Implication:* Checks complete in seconds even on large tables (millions of rows)

- **Date filtering:** Checks use `WHERE order_date >= CURRENT_DATE - 3` to limit scan scope
  - *Assumption:* `order_date` is indexed or used as a distribution/sort key
  - *Risk:* If `order_date` is not indexed, full table scans occur; performance degrades with table size

- **No joins:** Checks validate individual tables in isolation; no cross-table joins
  - *Benefit:* Avoids expensive join operations; checks remain fast
  - *Limitation:* Cannot detect referential integrity issues (e.g., orphaned foreign keys)

### Potential Bottlenecks
1. **Full table scans on large fact tables:** If `order_date` is not a sort key, `fct_orders` scan could be slow (millions of rows)
   - *Mitigation:* Ensure `order_date` is a sort key or distribution key in Redshift table definition
2. **Sequential check execution:** Checks run one-by-one in a single connection; no parallelization
   - *Impact:* Total runtime = sum of individual check times; if any check is slow, overall runtime increases
   - *Improvement:* Could parallelize checks using thread pool or async queries (not implemented)
3. **Connection overhead:** Creates single connection for all checks; reuses cursor
   - *Benefit:* Minimizes connection setup cost
   - *Risk:* If connection drops mid-execution, all remaining checks fail

### Partitioning & Distribution Strategy
- **Assumed distribution keys:** Checks reference tables like `fct_orders` and `fct_daily_revenue`; assume these are distributed by `customer_id` or `order_id` for efficient aggregations
- **Assumed sort keys:** Date columns (`order_date`, `revenue_date`) likely sorted to optimize date-range filters
- *Note:* Actual distribution/sort keys not visible in this code; inferred from query patterns

---

## Dependencies

### Upstream Dependencies
- **ETL DAG (Airflow):** This macro is called *after* the main ETL pipeline completes
  - *Implication:* All source tables (`marts.fct_orders`, `marts.dim_customers`, etc.) must be fully loaded and refreshed before checks run
  - *Risk:* If ETL fails or is incomplete, checks may report false negatives (e.g., low row counts due to partial load)

- **Redshift cluster:** Must be running and accessible
  - *Credentials:* Requires valid connection parameters (host, port, DB, user, password) from environment variables

- **quality_log table:** Must exist in Redshift (schema not specified; assumed to be in default schema or `public`)
  - *Note:* Table creation/schema not shown in this code; assumed to be pre-provisioned

### Downstream Dependencies
- **Alerting system:** Failures (especially `severity: "critical"`) likely trigger Airflow alerts or external notification systems
  - *Mechanism:* Airflow task failure or custom alert operator (not shown in this code)
  - *Consumers:* Data engineers, analytics team, on-call support

- **Data quality dashboards:** Results written to `quality_log` are likely queried by BI tools (Tableau, Looker) for monitoring
  - *Use case:* Executives/analysts view data quality trends over time

- **Downstream analytics/BI systems:** Depend on data quality checks passing before consuming mart tables
  - *Assumption:* Dashboards/reports only use data if quality checks pass (manual gate or automated validation)

### External Dependencies
- **Environment variables:** Redshift connection credentials must be set in Airflow environment
  - *Risk:* If credentials are missing or incorrect, macro fails immediately
  - *Security:* Credentials should be stored in Airflow Secrets or AWS Secrets Manager, not hardcoded

- **System clock:** Checks rely on `CURRENT_DATE` and `CURRENT_DATE - 1`; assumes Redshift server time is accurate
  - *Risk:* If server clock is skewed, date-based checks produce incorrect results

---

## Additional Notes

### Code Quality & Maintenance
- **Hardcoded checks:** All 8 checks are defined in the `CHECKS` list; adding new checks requires code modification
  - *Improvement:* Could externalize checks to a configuration file (JSON, YAML) for easier updates without redeployment
  
- **Error handling:** Exceptions during query execution are caught and logged; checks don't halt on individual failures
  - *Benefit:* Partial failures don't block entire validation run
  - *Limitation:* Connection errors would fail all remaining checks

- **Incomplete code:** The provided code snippet ends mid-function; the `results.append()` block for error cases is cut off
  - *Assumption:* Full implementation includes writing results to `quality_log` table and triggering alerts

### Recommended Enhancements
1. **Parameterize thresholds:** Move hardcoded thresholds (100 orders, $50K revenue, 2-day staleness) to configuration
2. **Parallel execution:** Use `concurrent.futures` or async queries to run checks in parallel
3. **Alerting integration:** Explicitly call Slack/email APIs or Airflow alert operators on critical failures
4. **Historical trending:** Query `quality_log` to detect degradation trends (e.g., row counts declining over time)
5. **Dynamic thresholds:** Calculate thresholds based on historical baselines (e.g., "alert if today's volume < 90% of 30-day average")