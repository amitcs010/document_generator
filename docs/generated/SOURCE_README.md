# document_generator

## Overview

This repository contains a comprehensive **e-commerce data warehouse** built on **Amazon Redshift**, designed to transform raw operational data into analytics-ready dimensional and fact tables. The pipeline ingests customer, product, order, and clickstream data from multiple sources, applies rigorous data quality checks, and produces business intelligence artifacts that power analytics, reporting, and strategic decision-making across the organization.

## Architecture

```
Raw Sources (CRM, S3, Clickstream)
         ↓
    [Staging Layer] — Deduplication, PII masking, data cleaning
         ↓
   [Transform Layer] — Business logic, sessionization, enrichment
         ↓
     [Marts Layer] — Dimensional & fact tables optimized for BI
         ↓
  BI Tools / Analytics / Dashboards
```

### Layer Descriptions

- **Staging Layer**: Ingests raw data from external sources (CRM systems, S3 data lakes, event streams), applies initial transformations (deduplication, PII masking, type casting), and creates a normalized foundation for downstream processing.

- **Transform Layer**: Applies business logic and intermediate transformations, including sessionization of clickstream events, order-item enrichment with product metrics, and customer attribution modeling.

- **Marts Layer**: Produces analytics-ready dimensional tables (customers, products) and fact tables (orders, daily revenue) optimized for BI queries, featuring aggregated metrics, RFM scoring, and performance indicators.

- **Utilities & Config**: Manages schema initialization, user permissions, and data quality validation to ensure pipeline reliability and data integrity.

## Repository Structure

```
document_generator/
├── config/
│   └── schema_setup.sql              # Redshift schema & user group initialization
├── macros/
│   └── data_quality_checks.py        # Data quality validation & alerting
├── staging/
│   ├── stg_raw_customers.sql         # CRM customer data transformation
│   ├── stg_raw_events.sql            # Clickstream event normalization
│   ├── stg_raw_orders.sql            # Order data cleaning & optimization
│   └── stg_raw_products.sql          # Product inventory staging (SCD Type 1)
├── transforms/
│   ├── int_customer_sessions.sql     # Session-level metrics & attribution
│   └── int_order_items.sql           # Order-item enrichment with margins
├── marts/
│   ├── dim_customers.sql             # Customer dimension with RFM & LTV
│   ├── dim_products.sql              # Product dimension with sales metrics
│   ├── fct_daily_revenue.sql         # Daily revenue fact table
│   └── fct_orders.sql                # Orders fact table
└── docs/
    └── generated/                    # Auto-generated documentation
```

## Components

### Staging Layer

| Component | Description | Sources | Targets |
|-----------|-------------|---------|---------|
| `stg_raw_customers.sql` | Deduplicates CRM customer records, masks PII, and optimizes for analytics queries | CRM System | `int_customer_sessions`, `dim_customers` |
| `stg_raw_events.sql` | Transforms raw JSON clickstream events into deduplicated, distributed table keyed by event_id | Event Stream (S3/Kafka) | `int_customer_sessions` |
| `stg_raw_orders.sql` | Cleans S3 order data, filters test orders, and creates optimized Redshift staging table | S3 Data Lake | `int_order_items`, `fct_orders` |
| `stg_raw_products.sql` | Applies SCD Type 1 methodology to product inventory data for historical tracking | Product Catalog | `int_order_items`, `dim_products` |

### Transform Layer

| Component | Description | Sources | Targets |
|-----------|-------------|---------|---------|
| `int_customer_sessions.sql` | Sessionizes clickstream events, computes session-level metrics, and applies attribution modeling | `stg_raw_events`, `stg_raw_customers` | `dim_customers`, `fct_orders` |
| `int_order_items.sql` | Joins order line items with product data to calculate item-level revenue, margin, and discount metrics | `stg_raw_orders`, `stg_raw_products` | `fct_orders`, `fct_daily_revenue` |

### Marts Layer

| Component | Description | Sources | Targets |
|-----------|-------------|---------|---------|
| `dim_customers.sql` | Customer dimension table enriched with RFM scoring and lifetime value (LTV) metrics | `stg_raw_customers`, `int_customer_sessions` | BI Tools, Analytics Dashboards |
| `dim_products.sql` | Product dimension table with aggregated sales performance metrics per product | `stg_raw_products`, `int_order_items` | BI Tools, Analytics Dashboards |
| `fct_daily_revenue.sql` | Fact table aggregating daily revenue metrics by product category, channel, and country | `int_order_items` | BI Tools, Revenue Dashboards |
| `fct_orders.sql` | Comprehensive fact table combining orders, line items, customers, and sessions for BI analysis | `stg_raw_orders`, `int_order_items`, `int_customer_sessions` | BI Tools, Order Analytics |

### Utilities & Config

| Component | Description |
|-----------|-------------|
| `config/schema_setup.sql` | Initializes Redshift database schemas, user groups, and access controls for the e-commerce warehouse |
| `macros/data_quality_checks.py` | Executes post-ETL data quality validations, logs results, and triggers failure alerts for data anomalies |

## Data Lineage

```
CRM System
    ↓
stg_raw_customers.sql
    ├─→ int_customer_sessions.sql ─→ dim_customers.sql
    └─→ fct_orders.sql

Event Stream
    ↓
stg_raw_events.sql
    ↓
int_customer_sessions.sql ─→ dim_customers.sql

S3 Data Lake (Orders)
    ↓
stg_raw_orders.sql
    ├─→ int_order_items.sql ─→ fct_orders.sql
    └─→ fct_orders.sql

Product Catalog
    ↓
stg_raw_products.sql
    ├─→ int_order_items.sql ─→ fct_orders.sql
    │                      ↓
    │                 fct_daily_revenue.sql
    └─→ dim_products.sql

[Data Quality Checks] ← All Marts
```

## Data Flow

**End-to-End Pipeline:**

1. **Ingestion**: Raw data is extracted from multiple sources—CRM systems, S3 data lakes, and clickstream event streams—and loaded into Redshift staging tables.

2. **Staging**: Raw data undergoes initial transformations including deduplication, PII masking, type casting, and test data filtering. Each staging table is optimized for downstream consumption.

3. **Transformation**: Intermediate tables apply business logic—sessionizing clickstream events into customer sessions, enriching order items with product metrics and margin calculations, and computing customer attribution.

4. **Marts**: Dimensional and fact tables are built from transformed data, producing analytics-ready artifacts with aggregated metrics, RFM scoring, and performance indicators.

5. **Quality Assurance**: Post-ETL data quality checks validate row counts, null distributions, and business rule compliance. Failures trigger alerts to data engineering teams.

6. **Consumption**: BI tools, dashboards, and analytics platforms consume mart tables to generate insights, reports, and strategic recommendations.

## Key Business Metrics

- **Customer Metrics**: RFM (Recency, Frequency, Monetary) scores, Customer Lifetime Value (LTV), acquisition cohorts
- **Product Metrics**: Sales performance, revenue contribution, inventory turnover, margin analysis
- **Revenue Metrics**: Daily revenue by category/channel/country, order value trends, discount impact analysis
- **Session Metrics**: Session duration, conversion rates, attribution by channel, customer journey analysis
- **Data Quality**: Record counts, null rates, duplicate detection, business rule compliance

## Getting Started

### Prerequisites

- **Redshift Cluster Access**: Active connection to the Redshift cluster with appropriate IAM permissions
- **SQL Client**: psql, DBeaver, or Redshift Query Editor
- **Python 3.8+**: For running data quality macros
- **AWS Credentials**: Configured for S3 access (data ingestion)
- **Database Permissions**: `CREATE TABLE`, `INSERT`, `SELECT` on warehouse schemas

### Running the ETL

1. **Initialize Schema** (one-time setup):
   ```sql
   psql -h <redshift-endpoint> -U <admin-user> -d <database> -f config/schema_setup.sql
   ```

2. **Execute Staging Layer**:
   ```sql
   psql -h <redshift-endpoint> -U <etl-user> -d <database> -f staging/stg_raw_customers.sql
   psql -h <redshift-endpoint> -U <etl-user> -d <database> -f staging/stg_raw_events.sql
   psql -h <redshift-endpoint> -U <etl-user> -d <database> -f staging/stg_raw_orders.sql
   psql -h <redshift-endpoint> -U <etl-user> -d <database> -f staging/stg_raw_products.sql
   ```

3. **Execute Transform Layer**:
   ```sql
   psql -h <redshift-endpoint> -U <etl-user> -d <database> -f transforms/int_customer_sessions.sql
   psql -h <redshift-endpoint> -U <etl-user> -d <database> -f transforms/int_order_items.sql
   ```

4. **Execute Marts Layer**:
   ```sql
   psql -h <redshift-endpoint> -U <etl-user> -d <database> -f marts/dim_customers.sql
   psql -h <redshift-endpoint> -U <etl-user> -d <database> -f marts/dim_products.sql
   psql -h <redshift-endpoint> -U <etl-user> -d <database> -f marts/fct_daily_revenue.sql
   psql -h <redshift-endpoint> -U <etl-user> -d <database> -f marts/fct_orders.sql
   ```

5. **Run Data Quality Checks**:
   ```bash
   python macros/data_quality_checks.py --config config/dq_config.yaml
   ```

### Adding New Components

1. **Create SQL file** in appropriate layer directory (`staging/`, `transforms/`, or `marts/`)
2. **Follow naming conventions**: `stg_*`, `int_*`, or `dim_*`/`fct_*`
3. **Document dependencies** in component header comments
4. **Add data quality rules** for new tables in `macros/data_quality_checks.py`
5. **Update this README** with new component details

## Documentation

- **Full Technical Documentation**: [`docs/generated/FULL_DOCUMENTATION.md`](docs/generated/FULL_DOCUMENTATION.md)
- **Component Index**: [`docs/generated/COMPONENT_INDEX.md`](docs/generated/COMPONENT_INDEX.md)
- **Data Lineage Details**: [`docs/generated/DATA_LINEAGE.md`](docs/generated/DATA_LINEAGE.md)
- **Per-File Documentation**: [`docs/generated/files/`](docs/generated/files/)

## Auto-Generated

This README was auto-generated by **RepoMigrator**. Push any commit to regenerate documentation.

**Last Updated**: 2026-04-15 12:07:18 UTC

---

**Repository**: [amitcs010/document_generator](https://github.com/amitcs010/document_generator)  
**Platform**: Amazon Redshift  
**Language**: SQL, Python