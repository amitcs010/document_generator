# Data Lineage

```mermaid
graph LR
    subgraph Sources["📊 Sources"]
        raw_customers["raw_customers"]
        raw_orders["raw_orders"]
        raw_events["raw_events"]
        raw_products["raw_products"]
    end

    subgraph Staging["🔄 Staging"]
        stg_raw_customers["stg_raw_customers.sql"]
        stg_raw_orders["stg_raw_orders.sql"]
        stg_raw_events["stg_raw_events.sql"]
    end

    subgraph Transforms["⚙️ Transforms"]
        int_order_items["int_order_items.sql"]
        int_customer_sessions["int_customer_sessions.sql"]
    end

    subgraph Marts["📈 Marts"]
        fct_orders["fct_orders.sql"]
        fct_daily_revenue["fct_daily_revenue.sql"]
        dim_customers["dim_customers.sql"]
        dim_products["dim_products.sql"]
    end

    subgraph QA["✓ Quality Assurance"]
        dq_checks["data_quality_checks.py"]
    end

    raw_customers --> stg_raw_customers
    raw_orders --> stg_raw_orders
    raw_events --> stg_raw_events

    stg_raw_customers --> int_customer_sessions
    stg_raw_orders --> int_order_items
    stg_raw_events --> int_customer_sessions

    stg_raw_customers --> dim_customers
    int_order_items --> dim_products
    int_order_items --> fct_daily_revenue
    stg_raw_orders --> fct_daily_revenue
    int_order_items --> fct_orders
    stg_raw_orders --> fct_orders
    int_customer_sessions --> fct_orders
    stg_raw_customers --> fct_orders
    fct_orders --> dim_customers

    fct_orders --> dq_checks
    fct_daily_revenue --> dq_checks
    dim_customers --> dq_checks
    dim_products --> dq_checks
    int_order_items --> dq_checks
    int_customer_sessions --> dq_checks
```

## Dependency Edges

| Source File | Target File | Via Table |
|---|---|---|
| `marts/fct_orders.sql` | `macros/data_quality_checks.py` | `marts.fct_orders` |
| `marts/fct_daily_revenue.sql` | `macros/data_quality_checks.py` | `marts.fct_daily_revenue` |
| `marts/dim_customers.sql` | `macros/data_quality_checks.py` | `marts.dim_customers` |
| `transforms/int_order_items.sql` | `macros/data_quality_checks.py` | `transforms.int_order_items` |
| `marts/dim_products.sql` | `macros/data_quality_checks.py` | `marts.dim_products` |
| `transforms/int_customer_sessions.sql` | `macros/data_quality_checks.py` | `transforms.int_customer_sessions` |
| `marts/fct_orders.sql` | `marts/dim_customers.sql` | `marts.fct_orders` |
| `staging/stg_raw_customers.sql` | `marts/dim_customers.sql` | `staging.stg_raw_customers` |
| `transforms/int_order_items.sql` | `marts/dim_products.sql` | `transforms.int_order_items` |
| `transforms/int_order_items.sql` | `marts/fct_daily_revenue.sql` | `transforms.int_order_items` |
| `staging/stg_raw_orders.sql` | `marts/fct_daily_revenue.sql` | `staging.stg_raw_orders` |
| `transforms/int_order_items.sql` | `marts/fct_orders.sql` | `transforms.int_order_items` |
| `staging/stg_raw_orders.sql` | `marts/fct_orders.sql` | `staging.stg_raw_orders` |
| `transforms/int_customer_sessions.sql` | `marts/fct_orders.sql` | `transforms.int_customer_sessions` |
| `staging/stg_raw_customers.sql` | `marts/fct_orders.sql` | `staging.stg_raw_customers` |
| `staging/stg_raw_events.sql` | `transforms/int_customer_sessions.sql` | `staging.stg_raw_events` |
| `staging/stg_raw_orders.sql` | `transforms/int_order_items.sql` | `staging.stg_raw_orders` |
