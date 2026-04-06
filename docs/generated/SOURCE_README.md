# document_generator

## Overview

This repository contains a comprehensive **e-commerce data warehouse** built on **Amazon Redshift**, designed to transform raw operational data into analytics-ready dimensional and fact tables. The pipeline ingests customer, product, order, and clickstream data from multiple sources, applies rigorous data quality checks, and delivers business intelligence insights through well-structured marts. It enables real-time revenue analytics, customer segmentation, and product performance tracking for stakeholders across the organization.

## Architecture

```
Raw Sources (CRM, S3, Clickstream) 
    ↓
[Staging Layer] - Deduplication, PII Masking, Validation
    ↓
[Transform Layer] - Sessionization, Enrichment, Aggregation
    ↓
[Marts Layer] - Dimensional & Fact Tables (Analytics-Ready)
    ↓
BI Tools / Analytics Dashboards / Reporting
```

**Layer Descriptions:**

- **Staging**: Ingests raw data from CRM systems, S3 buckets, and event streams. Applies initial transformations including deduplication, PII masking, and schema optimization for Redshift distribution.
- **Transform**: Builds intermediate tables that combine and enrich staged data. Includes sessionization of clickstream events, order-item enrichment, and customer-level aggregations.
- **Marts**: Produces final dimensional and fact tables optimized for BI consumption. Includes customer RFM scoring, product performance metrics, and daily revenue aggregations.
- **Utilities & Config**: Database initialization, schema setup, and automated data quality validation with alerting.

## Repository Structure

```
amitcs010/document_generator/
├── config/
│   └── schema_setup.sql                 # Redshift schema initialization & user groups
├── macros/
│   └── data_quality_checks.py           # DQ validation framework & alerting
├── staging/
│   ├── stg_raw_customers.sql            # CRM customer data transformation
│   ├── stg_raw_events.sql               # Clickstream event staging
│   ├── stg_raw_orders.sql               # S3 order data staging
│   └── stg_raw_products.sql             # Product master data staging
├── transforms/
│   ├── int_customer_sessions.sql        # Session-level aggregations
│   └── int_order_items.sql              # Order line item enrichment
├── marts/
│   ├── dim_customers.sql                # Customer dimension with RFM & LTV
│   ├── dim_products.sql                 # Product dimension with performance metrics
│   ├── fct_daily_revenue.sql            # Daily revenue fact table
│   └── fct_orders.sql                   # Orders fact table
└── docs/
    └── generated/                       # Auto-generated documentation
```

## Components

### Staging Layer

| Component | Description | Sources | Targets |
|-----------|-------------|---------|---------|
| `stg_raw_customers.sql` | Deduplicates CRM records, masks PII, optimizes for analytics | CRM System | `int_customer_sessions`, `dim_customers` |
| `stg_raw_events.sql` | Parses JSON clickstream payloads, deduplicates, distributes efficiently | Event Stream (S3/Kafka) | `int_customer_sessions` |
| `stg_raw_orders.sql` | Cleans S3 order data, filters test orders, optimizes distribution | S3 Data Lake | `int_order_items`, `fct_orders` |
| `stg_raw_products.sql` | Applies SCD Type 1 logic, full refresh of product master | Product Database | `int_order_items`, `dim_products` |

### Transform Layer

| Component | Description | Sources | Targets |
|-----------|-------------|---------|---------|
| `int_customer_sessions.sql` | Sessionizes clickstream events, computes session metrics & attribution | `stg_raw_events`, `stg_raw_customers` | `dim_customers`, `fct_orders` |
| `int_order_items.sql` | Enriches order line items with product data, calculates revenue/margin/discounts | `stg_raw_orders`, `stg_raw_products` | `fct_orders`, `fct_daily_revenue` |

### Marts Layer

| Component | Description | Sources | Targets |
|-----------|-------------|---------|---------|
| `dim_customers.sql` | Customer dimension with RFM scoring and lifetime value metrics | `int_customer_sessions`, `stg_raw_customers` | BI Dashboards |
| `dim_products.sql` | Product dimension enriched with aggregated sales performance metrics | `int_order_items`, `stg_raw_products` | BI Dashboards |
| `fct_daily_revenue.sql` | Daily revenue aggregated by product category, channel, and country | `int_order_items` | Revenue Analytics |
| `fct_orders.sql` | Comprehensive orders fact table combining orders, items, customers, and sessions | `int_order_items`, `int_customer_sessions`, `stg_raw_customers` | BI Dashboards |

### Utilities & Config

| Component | Description |
|-----------|-------------|
| `config/schema_setup.sql` | Initializes Redshift database schemas, user groups, and permissions for e-commerce warehouse |
| `macros/data_quality_checks.py` | Executes post-ETL data quality validations, logs results, and triggers failure alerts |

## Data Lineage

```
Raw CRM Data
    ↓
stg_raw_customers
    ├→ int_customer_sessions ──→ dim_customers
    │                        ├→ fct_orders
    │
Raw Clickstream Events
    ↓
stg_raw_events
    └→ int_customer_sessions

Raw S3 Orders
    ↓
stg_raw_orders
    ├→ int_order_items ──→ fct_orders
    │              ├→ fct_daily_revenue
    │
Raw Product Master
    ↓
stg_raw_products
    └→ int_order_items ──→ dim_products
```

## Data Flow

**End-to-End Process:**

1. **Ingestion**: Raw data arrives from three primary sources:
   - CRM system (customer records)
   - S3 data lake (order transactions)
   - Event streaming platform (clickstream events)

2. **Staging**: Each source is transformed independently:
   - Deduplication and validation
   - PII masking for sensitive fields
   - Schema optimization and Redshift distribution key assignment
   - Test data filtering

3. **Transformation**: Intermediate tables combine and enrich staged data:
   - Clickstream events are sessionized with attribution modeling
   - Order line items are enriched with product dimensions
   - Customer-level aggregations compute engagement metrics

4. **Marts**: Final analytics-ready tables are created:
   - Dimensional tables (`dim_customers`, `dim_products`) provide context
   - Fact tables (`fct_orders`, `fct_daily_revenue`) enable transactional analysis

5. **Consumption**: BI tools and dashboards query marts for reporting and analytics

6. **Quality Assurance**: Post-ETL data quality checks validate row counts, null distributions, and business rule compliance; failures trigger alerts

## Key Business Metrics

- **Customer Lifetime Value (LTV)**: Aggregated revenue per customer with RFM segmentation
- **Daily Revenue**: Aggregated by product category, sales channel, and geography
- **Product Performance**: Sales volume, revenue, margin, and discount metrics per SKU
- **Customer Engagement**: Session count, session duration, and attribution by channel
- **Order Metrics**: Order value, item count, discount rates, and fulfillment status

## Getting Started

### Prerequisites

- **Redshift Cluster Access**: Active connection to Redshift cluster with appropriate IAM permissions
- **SQL Client**: psql, DBeaver, or Redshift Query Editor
- **Python 3.8+**: Required for data quality macro execution
- **AWS Credentials**: S3 access for raw data ingestion
- **Permissions**: `CREATE TABLE`, `CREATE SCHEMA`, `INSERT`, `SELECT` on target database

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

1. **Create new SQL file** in appropriate layer (`staging/`, `transforms/`, or `marts/`)
2. **Follow naming convention**: `{layer}_{entity_name}.sql`
3. **Document dependencies** in file header comments
4. **Update data lineage** in this README
5. **Add DQ checks** in `macros/data_quality_checks.py` if applicable
6. **Test in development** before promoting to production

## Documentation

- **Full Technical Documentation**: [`docs/generated/FULL_DOCUMENTATION.md`](docs/generated/FULL_DOCUMENTATION.md)
- **Component Index**: [`docs/generated/COMPONENT_INDEX.md`](docs/generated/COMPONENT_INDEX.md)
- **Data Lineage Details**: [`docs/generated/DATA_LINEAGE.md`](docs/generated/DATA_LINEAGE.md)
- **Per-File Documentation**: [`docs/generated/files/`](docs/generated/files/)

## Auto-Generated

This README was auto-generated by **RepoMigrator**. Push any commit to regenerate.

**Last updated**: 2026-04-06 05:22:25 UTC

---

**Repository**: [amitcs010/document_generator](https://github.com/amitcs010/document_generator)  
**Platform**: Amazon Redshift  
**Language**: SQL, Python  
**Components**: 12 | **Dependencies**: 17