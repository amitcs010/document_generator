# document_generator

## Overview

This repository contains a comprehensive **e-commerce data warehouse** built on **Amazon Redshift**, designed to transform raw operational data into analytics-ready dimensional and fact tables. The pipeline ingests customer, product, order, and clickstream data from multiple sources, applies rigorous data quality checks, and delivers business intelligence metrics for revenue analysis, customer segmentation, and product performance tracking.

## Architecture

```
Raw Sources (CRM, S3, Clickstream)
           ↓
    [Staging Layer]
    (Deduplication, PII Masking, Type Casting)
           ↓
    [Transform Layer]
    (Aggregation, Attribution, Enrichment)
           ↓
    [Marts Layer]
    (Dimensional & Fact Tables)
           ↓
    BI Tools / Analytics / Reporting
```

### Layer Descriptions

- **Staging**: Cleanses and standardizes raw data from source systems (CRM, S3, event streams). Handles deduplication, PII masking, JSON parsing, and type conversions.
- **Transform**: Creates intermediate tables that aggregate, join, and enrich staging data. Applies business logic for session attribution, RFM scoring, and item-level metrics.
- **Marts**: Produces final dimensional and fact tables optimized for analytics queries. Includes customer dimensions with lifetime value, product performance metrics, and daily revenue aggregations.
- **Utilities & Config**: Provides schema initialization, data quality validation, and alerting infrastructure.

## Repository Structure

```
document_generator/
├── config/
│   └── schema_setup.sql              # Redshift warehouse initialization & user groups
├── staging/
│   ├── stg_raw_customers.sql         # CRM customer data transformation
│   ├── stg_raw_events.sql            # Clickstream event deduplication & parsing
│   ├── stg_raw_orders.sql            # S3 order data cleaning & type casting
│   └── stg_raw_products.sql          # Product inventory SCD Type 1 transformation
├── transforms/
│   ├── int_customer_sessions.sql     # Session aggregation with attribution
│   └── int_order_items.sql           # Order line item enrichment & metrics
├── marts/
│   ├── dim_customers.sql             # Customer dimension with RFM & LTV
│   ├── dim_products.sql              # Product dimension with sales metrics
│   ├── fct_daily_revenue.sql         # Daily revenue fact table
│   └── fct_orders.sql                # Order fact table (orders + line items + sessions)
├── macros/
│   └── data_quality_checks.py        # Post-ETL validation & alerting
├── docs/
│   └── generated/                    # Auto-generated documentation
└── README.md                         # This file
```

## Components

### Staging Layer

| Component | Description | Sources | Targets |
|-----------|-------------|---------|---------|
| `stg_raw_customers.sql` | Deduplicates CRM records, masks PII, optimizes for analytics | Raw CRM System | `dim_customers`, `fct_orders` |
| `stg_raw_events.sql` | Parses JSON clickstream payloads, deduplicates events, distributes by user | Event Stream (S3/Kafka) | `int_customer_sessions` |
| `stg_raw_orders.sql` | Cleans S3 order exports, casts types, filters test orders | S3 Data Lake | `int_order_items`, `fct_orders` |
| `stg_raw_products.sql` | Applies SCD Type 1 to product inventory, maintains current state | Product Catalog | `dim_products`, `int_order_items` |

### Transform Layer

| Component | Description | Sources | Targets |
|-----------|-------------|---------|---------|
| `int_customer_sessions.sql` | Aggregates events into sessions, calculates attribution & engagement metrics | `stg_raw_events` | `fct_orders`, `dim_customers` |
| `int_order_items.sql` | Joins order line items with product data, calculates revenue, margin, discounts | `stg_raw_orders`, `stg_raw_products` | `fct_orders`, `fct_daily_revenue` |

### Marts Layer

| Component | Description | Sources | Targets |
|-----------|-------------|---------|---------|
| `dim_customers.sql` | Customer dimension with RFM scoring, lifetime value, segmentation | `stg_raw_customers`, `int_customer_sessions` | BI Tools, Dashboards |
| `dim_products.sql` | Product dimension enriched with aggregated sales performance | `stg_raw_products`, `int_order_items` | BI Tools, Dashboards |
| `fct_daily_revenue.sql` | Daily revenue aggregated by product category, channel, country | `int_order_items` | Revenue Dashboards, Executive Reports |
| `fct_orders.sql` | Comprehensive order fact table combining orders, items, customers, sessions | `stg_raw_orders`, `int_order_items`, `stg_raw_customers`, `int_customer_sessions` | BI Tools, Order Analytics |

### Utilities & Config

| Component | Description |
|-----------|-------------|
| `config/schema_setup.sql` | Initializes Redshift schemas, creates user groups, sets permissions for warehouse |
| `macros/data_quality_checks.py` | Executes post-ETL validations (row counts, null checks, referential integrity), logs results, triggers alerts on failures |

## Data Lineage

```
Raw CRM Data
    ↓
stg_raw_customers
    ├→ dim_customers (with RFM/LTV)
    └→ fct_orders

Raw Clickstream Events
    ↓
stg_raw_events
    ↓
int_customer_sessions
    ├→ dim_customers
    └→ fct_orders

Raw S3 Orders
    ↓
stg_raw_orders
    ↓
int_order_items
    ├→ fct_orders
    ├→ fct_daily_revenue
    └→ dim_products

Raw Product Catalog
    ↓
stg_raw_products
    ├→ dim_products
    └→ int_order_items
```

## Data Flow

1. **Ingestion**: Raw data arrives from three sources:
   - CRM system → `stg_raw_customers`
   - Clickstream events (S3/Kafka) → `stg_raw_events`
   - Order exports (S3) → `stg_raw_orders`
   - Product catalog → `stg_raw_products`

2. **Staging**: Each source is cleaned, deduplicated, and type-cast. PII is masked in customer data. JSON payloads are parsed.

3. **Transformation**: Staging tables are joined and aggregated:
   - Events are windowed into sessions with attribution
   - Order items are enriched with product metrics (margin, discount)

4. **Marts**: Final tables are built for analytics:
   - Dimensions: `dim_customers` (with RFM/LTV), `dim_products` (with sales metrics)
   - Facts: `fct_orders` (comprehensive), `fct_daily_revenue` (aggregated)

5. **Quality Checks**: Post-ETL validation runs via `data_quality_checks.py`, checking row counts, nulls, and referential integrity. Failures trigger alerts.

6. **Consumption**: BI tools query marts for dashboards, reports, and analytics.

## Key Business Metrics

- **Customer Lifetime Value (LTV)**: Total revenue per customer
- **RFM Scoring**: Recency, Frequency, Monetary segmentation
- **Daily Revenue**: Aggregated by product category, channel, country
- **Product Performance**: Sales volume, margin, discount metrics per product
- **Order Analytics**: Order count, average order value, customer attribution
- **Session Metrics**: User engagement, attribution by channel

## Getting Started

### Prerequisites

- **Redshift Cluster**: Active cluster with appropriate compute capacity
- **IAM Permissions**: Access to create schemas, tables, and execute queries
- **S3 Access**: Read permissions on data lake buckets
- **Python 3.8+**: For running data quality checks (`macros/data_quality_checks.py`)
- **SQL Client**: `psql`, DBeaver, or Redshift Query Editor

### Running the ETL

1. **Initialize Warehouse** (one-time):
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
   python macros/data_quality_checks.py \
     --redshift-host <endpoint> \
     --redshift-user <user> \
     --redshift-password <password> \
     --redshift-db <database>
   ```

### Adding New Components

1. **New Staging Table**: Create `staging/stg_raw_<source>.sql` following the deduplication and type-casting patterns in existing staging files.
2. **New Transform**: Create `transforms/int_<business_concept>.sql` joining staging tables with appropriate aggregations.
3. **New Mart**: Create `marts/dim_<entity>.sql` or `marts/fct_<event>.sql` in the marts directory.
4. **Update Data Quality**: Add validation rules to `macros/data_quality_checks.py` for new tables.
5. **Document**: Add component description to this README and regenerate auto-generated docs.

## Documentation

- **Full Technical Documentation**: [`docs/generated/FULL_DOCUMENTATION.md`](docs/generated/FULL_DOCUMENTATION.md)
- **Component Index**: [`docs/generated/COMPONENT_INDEX.md`](docs/generated/COMPONENT_INDEX.md)
- **Data Lineage**: [`docs/generated/DATA_LINEAGE.md`](docs/generated/DATA_LINEAGE.md)
- **Per-File Documentation**: [`docs/generated/files/`](docs/generated/files/)

## Auto-Generated

This README was auto-generated by [RepoMigrator](https://github.com/amitcs010/document_generator). Push any commit to regenerate.

**Last updated**: 2026-04-15 11:00:49 UTC

---

**Repository**: [amitcs010/document_generator](https://github.com/amitcs010/document_generator)  
**Platform**: Amazon Redshift  
**Language**: SQL (+ Python for utilities)