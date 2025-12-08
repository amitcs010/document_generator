Error after 3 attempts: 429 POST https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?%24alt=json%3Benum-encoding%3Dint: You exceeded your current quota, please check your plan and billing details. For more information on this error, head to: https://ai.google.dev/gemini-api/docs/rate-limits. To monitor your current usage, head to: https://ai.dev/usage?tab=rate-limit. 
* Quota exceeded for metric: generativelanguage.googleapis.com/generate_content_free_tier_requests, limit: 5, model: gemini-2.5-flash
Please retry in 23.661327365s.

## Visual Data Lineage

![Complete Data Lineage](lineage_diagram.png)

*The diagram above shows the complete data lineage across all SQL files in the repository.*



## Detailed File Inventory

| # | File Name | Type | Purpose | Sources | Targets |
|---|-----------|------|---------|---------|----------|
| 1 | `mdl_customers.sql` | script | Creates a 'model' table for customer data by selec | src_customers | mdl_customers |
| 2 | `mdl_products.sql` | script | This script creates or recreates the `mdl_products | src_products | mdl_products |
| 3 | `mdl_sales.sql` | script | Creates a modeled sales table (`mdl_sales`) by sel | src_sales | mdl_sales |
| 4 | `sp_load_models.sql` | stored_procedure | This stored procedure creates or replaces three mo | src_sales, src_customers, src_products | mdl_sales, mdl_customers, mdl_products |
| 5 | `sp_sales_cust_prod.sql` | view | This SQL creates a view that combines sales transa | mdl_sales, mdl_customers, mdl_products | vw_sales_customer_product |
| 6 | `src_products.sql` | script | This SQL script defines and creates the `src_produ | - | src_products |
| 7 | `src_sales.sql` | script | script SQL file | - | if |
| 8 | `src_customers.sql` | script | script SQL file | - | if |


---
*Generated: 2025-12-08 06:09:36*
*Files: 8 | Tables: 7 | Relationships: 12*
