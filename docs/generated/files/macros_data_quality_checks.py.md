# Data Quality Checks Documentation

**Purpose**
Executes post-ETL data quality validations against Redshift warehouse tables (facts and dimensions) and logs results to a quality audit table. Validates row counts, null values, data ranges, uniqueness, and freshness across 8 critical checks spanning orders, customers, products, and sessions domains. Failures trigger alerts via Airflow integration.

**Inputs**
- Redshift connection parameters (host, port, database, user, password) via environment variables
- 8 predefined quality check definitions with SQL queries, thresholds, operators, and severity levels
- Target tables: `marts.fct_orders`, `marts.dim_customers`, `marts.dim_products`, `marts.fct_daily_revenue`, `transforms.int_customer_sessions`, `transforms.int_order_items`

**Outputs**
- Results list containing per-check metrics: check name, table, actual value, expected condition, pass/fail status, timestamp, and error messages
- Console output with pass/fail status and actual vs. expected values
- (Implied) Rows written to `quality_log` table in Redshift for audit trail

**Key Transformations**
- Executes parameterized SQL queries against Redshift and extracts scalar results
- Compares actual values against thresholds using operators (`>=`, `<=`, `==`, `>`, `<`)
- Constructs result dictionaries with normalized metadata (severity, description, ISO timestamp)
- Exception handling captures query failures without halting execution

**Dependencies**
- `psycopg2` (Redshift/PostgreSQL adapter)
- Environment variables: `REDSHIFT_HOST`, `REDSHIFT_PORT`, `REDSHIFT_DB`, `REDSHIFT_USER`, `REDSHIFT_PASS`
- Airflow DAG orchestration (post-ETL trigger)

**Notes**
- File appears truncated (incomplete exception handler); final result logging to quality_log table not shown
- Severity levels (critical/warning) defined but not used for alerting logic in visible code
- Default Redshift credentials hardcoded as fallbacks; production should enforce env var requirement