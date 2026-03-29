"""
data_quality_checks.py
----------------------
Runs data quality checks against the Redshift warehouse after each ETL run.
Results are written to the quality_log table and failures trigger alerts.

Usage: Called by Airflow after the ETL DAG completes.
"""

import psycopg2
import os
import json
from datetime import datetime, timezone


# Connection config (from environment variables)
REDSHIFT_HOST = os.environ.get("REDSHIFT_HOST", "my-cluster.xxxx.us-east-1.redshift.amazonaws.com")
REDSHIFT_PORT = os.environ.get("REDSHIFT_PORT", "5439")
REDSHIFT_DB = os.environ.get("REDSHIFT_DB", "analytics")
REDSHIFT_USER = os.environ.get("REDSHIFT_USER", "etl_user")
REDSHIFT_PASS = os.environ.get("REDSHIFT_PASS", "")


# ── Quality Check Definitions ──

CHECKS = [
    {
        "name": "orders_not_empty",
        "table": "marts.fct_orders",
        "sql": "SELECT COUNT(*) FROM marts.fct_orders WHERE order_date = CURRENT_DATE - 1",
        "threshold": 100,
        "operator": ">=",
        "severity": "critical",
        "description": "Yesterday should have at least 100 orders",
    },
    {
        "name": "orders_no_null_revenue",
        "table": "marts.fct_orders",
        "sql": "SELECT COUNT(*) FROM marts.fct_orders WHERE gross_revenue IS NULL AND order_date >= CURRENT_DATE - 3",
        "threshold": 0,
        "operator": "==",
        "severity": "critical",
        "description": "No orders should have NULL gross_revenue",
    },
    {
        "name": "orders_revenue_range",
        "table": "marts.fct_orders",
        "sql": "SELECT COUNT(*) FROM marts.fct_orders WHERE gross_revenue < 0 OR gross_revenue > 50000",
        "threshold": 0,
        "operator": "==",
        "severity": "warning",
        "description": "No orders with negative or suspiciously high revenue",
    },
    {
        "name": "customers_unique",
        "table": "marts.dim_customers",
        "sql": """
            SELECT COUNT(*) - COUNT(DISTINCT customer_id) 
            FROM marts.dim_customers
        """,
        "threshold": 0,
        "operator": "==",
        "severity": "critical",
        "description": "Customer dimension should have no duplicate customer_ids",
    },
    {
        "name": "products_have_cost",
        "table": "marts.dim_products",
        "sql": """
            SELECT COUNT(*) FROM marts.dim_products 
            WHERE unit_cost IS NULL OR unit_cost <= 0 
            AND product_status = 'Active'
        """,
        "threshold": 0,
        "operator": "==",
        "severity": "warning",
        "description": "Active products should have a valid unit cost",
    },
    {
        "name": "daily_revenue_freshness",
        "table": "marts.fct_daily_revenue",
        "sql": "SELECT DATEDIFF(day, MAX(revenue_date), CURRENT_DATE) FROM marts.fct_daily_revenue",
        "threshold": 2,
        "operator": "<=",
        "severity": "critical",
        "description": "Daily revenue should be no more than 2 days stale",
    },
    {
        "name": "sessions_event_count",
        "table": "transforms.int_customer_sessions",
        "sql": """
            SELECT COUNT(*) FROM transforms.int_customer_sessions 
            WHERE event_count <= 0
        """,
        "threshold": 0,
        "operator": "==",
        "severity": "warning",
        "description": "All sessions should have at least 1 event",
    },
    {
        "name": "margin_sanity",
        "table": "transforms.int_order_items",
        "sql": """
            SELECT COUNT(*) FROM transforms.int_order_items 
            WHERE margin_pct < -50 OR margin_pct > 99
        """,
        "threshold": 10,
        "operator": "<=",
        "severity": "warning",
        "description": "Very few items should have extreme margin percentages",
    },
]


def get_connection():
    """Create a Redshift connection."""
    return psycopg2.connect(
        host=REDSHIFT_HOST,
        port=REDSHIFT_PORT,
        dbname=REDSHIFT_DB,
        user=REDSHIFT_USER,
        password=REDSHIFT_PASS,
    )


def evaluate_check(actual_value, threshold, operator):
    """Evaluate whether a check passes."""
    if operator == ">=":
        return actual_value >= threshold
    elif operator == "<=":
        return actual_value <= threshold
    elif operator == "==":
        return actual_value == threshold
    elif operator == ">":
        return actual_value > threshold
    elif operator == "<":
        return actual_value < threshold
    else:
        raise ValueError(f"Unknown operator: {operator}")


def run_checks():
    """Run all data quality checks and return results."""
    conn = get_connection()
    cursor = conn.cursor()
    results = []
    run_timestamp = datetime.now(timezone.utc).isoformat()

    for check in CHECKS:
        try:
            cursor.execute(check["sql"])
            actual_value = cursor.fetchone()[0]
            passed = evaluate_check(actual_value, check["threshold"], check["operator"])

            results.append({
                "check_name": check["name"],
                "table": check["table"],
                "description": check["description"],
                "severity": check["severity"],
                "expected": f"{check['operator']} {check['threshold']}",
                "actual": actual_value,
                "passed": passed,
                "run_at": run_timestamp,
            })

            status = "PASS" if passed else "FAIL"
            print(f"  [{status}] {check['name']}: actual={actual_value} (expected {check['operator']} {check['threshold']})")

        except Exception as e:
            results.append({
                "check_name": check["name"],
                "table": check["table"],
                "description": check["description"],
                "severity": check["severity"],
                "expected": f"{check['operator']} {check['threshold']}",
                "actual": None,
                "passed": False,
                "error": str(e),
                "run_at": run_timestamp,
            })
            print(f"  [ERROR] {check['name']}: {e}")

    cursor.close()
    conn.close()
    return results


def log_results_to_redshift(results):
    """Write check results to the quality_log table."""
    conn = get_connection()
    cursor = conn.cursor()

    # Ensure table exists
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS monitoring.data_quality_log (
            check_name VARCHAR(100),
            table_name VARCHAR(100),
            severity VARCHAR(20),
            passed BOOLEAN,
            actual_value VARCHAR(200),
            expected_value VARCHAR(200),
            error_message VARCHAR(500),
            run_at TIMESTAMP DEFAULT GETDATE()
        )
    """)

    for r in results:
        cursor.execute("""
            INSERT INTO monitoring.data_quality_log 
            (check_name, table_name, severity, passed, actual_value, expected_value, error_message, run_at)
            VALUES (%s, %s, %s, %s, %s, %s, %s, GETDATE())
        """, (
            r["check_name"], r["table"], r["severity"],
            r["passed"], str(r.get("actual", "")),
            r["expected"], r.get("error", None),
        ))

    conn.commit()
    cursor.close()
    conn.close()


def main():
    print(f"Running {len(CHECKS)} data quality checks...")
    print("=" * 60)

    results = run_checks()

    print("=" * 60)
    passed = sum(1 for r in results if r["passed"])
    failed = sum(1 for r in results if not r["passed"])
    critical_failures = sum(1 for r in results if not r["passed"] and r["severity"] == "critical")

    print(f"\nResults: {passed} passed, {failed} failed ({critical_failures} critical)")

    # Log to Redshift
    try:
        log_results_to_redshift(results)
        print("Results logged to monitoring.data_quality_log")
    except Exception as e:
        print(f"WARNING: Could not log results: {e}")

    # Exit with error code if critical failures
    if critical_failures > 0:
        print(f"\nFATAL: {critical_failures} critical check(s) failed!")
        exit(1)


if __name__ == "__main__":
    main()
