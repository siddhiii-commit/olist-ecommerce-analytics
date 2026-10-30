# Olist E-Commerce Analytics

**Python (Pandas) · MySQL 8 · Jupyter Notebook**  
**Status:** Data cleaning and SQL analysis scripts prepared; Power BI dashboard planned.

## Overview and business problem

This project examines the Brazilian Olist e-commerce dataset to understand order activity, sales composition, customer behavior, delivery performance, and payment reconciliation. The objective is to turn multi-table transactional data into reliable business measures while explicitly tracking data-quality exceptions.

## Dataset

Source: [Brazilian E-Commerce Public Dataset by Olist (Kaggle)](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce). The source comprises nine related CSV datasets: customers, sellers, products, categories, orders, order items, payments, reviews, and geolocation. Download the dataset from the source and review its terms. Raw and cleaned CSVs are deliberately excluded from this repository due to size and potential free-text personal information.

## Objectives and questions

- Assess monthly order activity, item value, freight, and payment methods.
- Compare product categories, customer locations, and seller activity.
- Examine observed delivery times, late deliveries, and order cancellations.
- Evaluate repeat-customer activity and first-purchase cohorts.
- Identify missing keys, unusual timestamps, and order-payment mismatches.

## Project structure

```text
notebooks/01_data_loading_cleaning.ipynb  # Pandas quality audit and cleaned-data export
sql/01_data_loading.sql                   # MySQL staging and dimensional model
sql/02_eda_questions.sql                  # 25 exploratory questions
sql/03_business_insights.sql              # 10 further business questions
requirements.txt
```

## Cleaning and validation

The notebook reviews missing values, key uniqueness, foreign-key coverage, delivery timestamp anomalies, invalid product/geolocation attributes, duplicated geolocation observations, and payment-versus-item totals. It builds quality flags and a representative coordinate lookup by ZIP prefix. Original notebook outputs have been removed from the public version to reduce disclosure risk; inspect and rerun the cells for results.

## MySQL model

The SQL defines five dimensions (`DimCustomer`, `DimSeller`, `DimProduct`, `DimDate`, `DimOrder`) and three facts (`FactOrderItem`, `FactPayment`, `FactReview`). Keeping payments and reviews in separate facts avoids multiplication when joining multiple one-to-many relationships. The query scripts use these tables for exploratory metrics and business questions.

## KPIs and interpretation

The SQL asks for monthly orders, item and freight value, delivery duration, on-time delivery, customer repeat activity, product-category contribution, payment mix, review distribution, and financial reconciliation exceptions. These are **defined analytical questions, not independently verified final result claims**. No dashboard, numerical finding, or business recommendation is presented as complete without executed outputs.

## Reproduction

1. Install Python dependencies with `pip install -r requirements.txt`.
2. Download the original nine CSVs and place them under `data/raw/` (the notebook expects filenames containing their Olist table names). Run the notebook from `notebooks/` to inspect and export cleaned data under `data/cleaned/`.
3. In `sql/01_data_loading.sql`, replace `/REPLACE_WITH_ABSOLUTE_PATH_TO_CLEANED_DATA/` with your absolute cleaned CSV directory. Configure MySQL 8's `LOCAL INFILE` safely through your own environment and review the script before running it in a dedicated database.
4. Execute `sql/01_data_loading.sql`, verify the table counts, then run the EDA and business-insight scripts.

The SQL scripts have not been independently executed in this published environment. The data-loading script may need line-ending or permissions adjustments for your installation.

## Status and next steps

- Completed in supplied files: Pandas cleaning/quality-audit notebook and drafted SQL model, EDA, and business-question scripts.
- To validate: Re-run scripts, record checked query outputs, and cross-check aggregates against the cleaned CSVs.
- Planned: Build and document a Power BI dashboard, add screenshots and verified business recommendations.

No Power BI dashboard or production deployment is claimed.
