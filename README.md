# document_generator

## Overview

This repository contains a comprehensive **e-commerce data warehouse** built on **Amazon Redshift**, designed to transform raw operational data into analytics-ready dimensional and fact tables. The pipeline ingests customer, product, order, and clickstream data from multiple sources, applies rigorous data quality checks, and produces business intelligence artifacts for executive reporting, customer analytics, and revenue analysis.

## Architecture

```
Raw Sources (CRM, S3, Clickstream)
         ↓
    [Staging Layer] - Deduplication, PII masking, JSON parsing
         ↓
   [Transform Layer] - Business logic, aggregations, attribution
         ↓
     [Marts Layer] - Dimensional & fact tables optimized for BI
         ↓
BI Tools / Analytics / Executive Dashboards
```

**Layer Descriptions:**

- **Staging**: Ingests raw data from external sources (CRM systems, S3, event streams), applies initial transformations (deduplication, type casting, PII masking), and creates a clean foundation for downstream processing.
- **Transform**: Applies business logic and complex calculations (RFM scoring, session attribution, margin calculations) to create reusable intermediate tables.
- **Marts**: Produces final analytics-ready dimensional and fact tables optimized for BI queries, dashboards, and reporting.
- **Utilities & Config**: Provides schema initialization, data quality validation, and monitoring infrastructure.

## Repository Structure

```
document_generator/
├── config/
│   └── schema_setup.sql              # Redshift warehouse initialization & user groups
├── staging/
│   ├── stg_raw_customers.sql         # CRM customer data transformation
│   ├── stg_raw_events.sql            # Clickstream event parsing & deduplication
│   ├── stg_raw_orders.sql            # S3 order data cleaning & optimization
│   └── stg_raw_products.sql          # Product inventory SCD Type 1 transformation
├── transforms/
│   ├── int_customer_sessions.sql     # Session attribution & metrics
│   └── int_order_items.sql           # Item-level revenue & margin calculations
├── marts/
│   ├── dim_customers.sql             # Customer dimension with RFM & LTV
│   ├── dim_products.sql              # Product dimension with performance metrics
│   ├── fct_daily_revenue.sql         # Daily revenue aggregations by category/channel/country
│   └── fct_orders.sql                # Order fact table for BI analysis
├── macros/
│   └── data_quality_checks.py        # Automated DQ validation & alerting
└── docs/
    └── generated/                    # Auto-generated documentation
```

## Components

### Staging Layer

| Component | Description | Sources | Targets |
|-----------|-------------|---------|---------|
| `stg_raw_customers.sql` | Deduplicates CRM records, masks PII (email, phone), standardizes formats | CRM System | `int_customer_sessions`, `dim_customers` |
| `stg_raw_events.sql` | Parses JSON clickstream payloads, deduplicates events, distributes by session ID | Event Stream (S3/Kafka) | `int_customer_sessions` |
| `stg_raw_orders.sql` | Cleans S3 order exports, filters test orders, optimizes for Redshift distribution | S3 Data Lake | `int_order_items`, `fct_orders` |
| `stg_raw_products.sql` | Applies SCD Type 1 to product inventory, enriches with category hierarchies | Product Database | `int_order_items`, `dim_products` |

### Transform Layer

| Component | Description | Sources | Targets |
|-----------|-------------|---------|---------|
| `int_customer_sessions.sql` | Aggregates events into sessions, calculates session duration, applies first-touch attribution | `stg_raw_events`, `stg_raw_customers` | `dim_customers`, `fct_orders` |
| `int_order_items.sql` | Joins orders with products, calculates item-level revenue, COGS, margin, and discount impact | `stg_raw_orders`, `stg_raw_products` | `fct_orders`, `fct_daily_revenue` |

### Marts Layer

| Component | Description | Sources | Targets |
|-----------|-------------|---------|---------|
| `dim_customers.sql` | Customer dimension with RFM segmentation, lifetime value, acquisition channel, churn risk scoring | `stg_raw_customers`, `int_customer_sessions` | BI Dashboards, Customer Analytics |
| `dim_products.sql` | Product dimension enriched with YTD sales, average rating, inventory levels, category performance | `stg_raw_products`, `int_order_items` | BI Dashboards, Product Analytics |
| `fct_daily_revenue.sql` | Daily revenue aggregations by product category, sales channel, and country for executive reporting | `int_order_items` | Executive Dashboards, Revenue Reports |
| `fct_orders.sql` | Comprehensive order fact table combining orders, line items, customers, and sessions for multi-dimensional analysis | `stg_raw_orders`, `int_order_items`, `int_customer_sessions` | BI Tools, Ad-hoc Analysis |

### Utilities & Config

| Component | Description |
|-----------|-------------|
| `config/schema_setup.sql` | Initializes Redshift warehouse schemas, creates user groups, sets permissions, and configures distribution keys |
| `macros/data_quality_checks.py` | Executes post-ETL data quality validations (null checks, cardinality, referential integrity), logs results, triggers PagerDuty alerts on failures |

## Data Lineage

```
CRM System
    ↓
stg_raw_customers ──┐
                    ├──→ int_customer_sessions ──┐
stg_raw_events ─────┘                            ├──→ dim_customers
                                                 │
                                                 └──→ fct_orders
S3 Order Data                                         ↑
    ↓                                                 │
stg_raw_orders ──┐                                    │
                 ├──→ int_order_items ───────────────┘
Product DB       │        ↓
    ↓            │    fct_daily_revenue
stg_raw_products ┘        ↓
                      dim_products
```

## Data Flow

**End-to-End Pipeline:**

1. **Ingestion**: Raw data arrives from three primary sources:
   - **CRM System** → Customer records (daily full refresh)
   - **S3 Data Lake** → Order transactions and product inventory (hourly incremental)
   - **Event Stream** → Clickstream events (real-time or batch)

2. **Staging**: Each source is transformed independently:
   - Deduplication and type standardization
   - PII masking for compliance (GDPR, CCPA)
   - JSON parsing and schema validation
   - Test data filtering

3. **Transformation**: Intermediate tables apply business logic:
   - Session attribution (first-touch, last-touch)
   - RFM scoring and customer segmentation
   - Item-level margin and discount calculations
   - Slowly Changing Dimension (SCD) handling

4. **Marts**: Final analytics tables are created:
   - Dimensional tables (customers, products) for drill-down analysis
   - Fact tables (orders, daily revenue) for aggregations and KPI reporting

5. **Quality Assurance**: Post-load validation:
   - Row count reconciliation with source systems
   - Null/cardinality checks on critical columns
   - Referential integrity validation
   - Automated alerting on anomalies

6. **Consumption**: BI tools query marts for dashboards, reports, and ad-hoc analysis.

## Key Business Metrics

- **Customer Lifetime Value (LTV)**: Total revenue per customer, segmented by acquisition channel
- **RFM Scores**: Recency, Frequency, Monetary segmentation for customer targeting
- **Daily Revenue**: Aggregated by product category, sales channel, and geography
- **Product Performance**: YTD sales, average rating, inventory turnover
- **Order Metrics**: Average order value, item-level margin, discount impact
- **Session Attribution**: First-touch and last-touch channel attribution for marketing ROI
- **Data Quality Score**: Percentage of records passing validation checks

## Getting Started

### Prerequisites

- **Redshift Cluster Access**: Ensure you have read/write permissions on the target Redshift cluster
- **IAM Permissions**: S3 access for data ingestion, CloudWatch for logging
- **SQL Client**: psql, DBeaver, or Redshift Query Editor
- **Python 3.8+**: For running data quality macros
- **Git**: For version control and CI/CD integration

### Running the ETL

1. **Initialize the warehouse** (one-time setup):
   ```bash
   psql -h <redshift-endpoint> -U <admin-user> -d <database> -f config/schema_setup.sql
   ```

2. **Execute staging transformations**:
   ```bash
   psql -h <redshift-endpoint> -U <etl-user> -d <database> -f staging/stg_raw_customers.sql
   psql -h <redshift-endpoint> -U <etl-user> -d <database> -f staging/stg_raw_events.sql
   psql -h <redshift-endpoint> -U <etl-user> -d <database> -f staging/stg_raw_orders.sql
   psql -h <redshift-endpoint> -U <etl-user> -d <database> -f staging/stg_raw_products.sql
   ```

3. **Execute transform layer**:
   ```bash
   psql -h <redshift-endpoint> -U <etl-user> -d <database> -f transforms/int_customer_sessions.sql
   psql -h <redshift-endpoint> -U <etl-user> -d <database> -f transforms/int_order_items.sql
   ```

4. **Build marts**:
   ```bash
   psql -h <redshift-endpoint> -U <etl-user> -d <database> -f marts/dim_customers.sql
   psql -h <redshift-endpoint> -U <etl-user> -d <database> -f marts/dim_products.sql
   psql -h <redshift-endpoint> -U <etl-user> -d <database> -f marts/fct_orders.sql
   psql -h <redshift-endpoint> -U <etl-user> -d <database> -f marts/fct_daily_revenue.sql
   ```

5. **Run data quality checks**:
   ```bash
   python macros/data_quality_checks.py --config config/dq_rules.yaml
   ```

### Adding New Components

1. **Create a new SQL file** in the appropriate layer (`staging/`, `transforms/`, or `marts/`)
2. **Follow naming conventions**:
   - Staging: `stg_<source>_<entity>.sql`
   - Transforms: `int_<business_concept>.sql`
   - Marts: `dim_<entity>.sql` or `fct_<event>.sql`
3. **Document dependencies** in the file header (source tables, business logic)
4. **Add data quality rules** in `macros/data_quality_checks.py`
5. **Update this README** and commit to trigger documentation regeneration

## Documentation

- **Full Technical Documentation**: [`docs/generated/FULL_DOCUMENTATION.md`](docs/generated/FULL_DOCUMENTATION.md)
- **Component Index**: [`docs/generated/COMPONENT_INDEX.md`](docs/generated/COMPONENT_INDEX.md)
- **Data Lineage**: [`docs/generated/DATA_LINEAGE.md`](docs/generated/DATA_LINEAGE.md)
- **Per-File Documentation**: [`docs/generated/files/`](docs/generated/files/)

## Auto-Generated

This README was auto-generated by **RepoMigrator**. Push any commit to regenerate documentation and keep this file in sync with repository changes.

**Last updated**: 2026-04-06 09:18:53 UTC

---

**Maintainers**: Data Engineering Team  
**Repository**: [amitcs010/document_generator](https://github.com/amitcs010/document_generator)