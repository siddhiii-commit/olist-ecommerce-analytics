/*
  Olist e-commerce analytics — exploratory data analysis query pack
  ================================================================
  Database: MySQL 8.0.16+
  Prerequisite: run olist_mysql_data_loading.sql first.

  Scope: descriptive EDA only. These queries summarize patterns and data
  quality; they do not make business recommendations or causal claims.

  Important grain rules:
    - FactOrderItem: one row per order line. Sum price/freight here.
    - FactPayment: one row per payment sequence. Sum payments here.
    - FactReview: one source review row. Count/average reviews here.
    - Never join these raw fact tables directly to each other by order_id.
      Aggregate each fact to order grain first when comparing them.
*/

/* =====================================================================
   1. SALES AND REVENUE TRENDS
   ===================================================================== */

-- Q1. How many orders were purchased in each month, by order status?
-- Counts are order-grain and use purchase month from DimOrder.
SELECT DATE_FORMAT(order_purchase_timestamp, '%Y-%m') AS purchase_month,
       order_status,
       COUNT(*) AS order_count
FROM DimOrder
GROUP BY DATE_FORMAT(order_purchase_timestamp, '%Y-%m'), order_status
ORDER BY purchase_month, order_status;

-- Q2. What are the monthly item-price and freight totals?
-- Item price is gross item value in the source; freight is shown separately.
-- This includes all item rows, including any non-delivered order statuses.
SELECT DATE_FORMAT(o.order_purchase_timestamp, '%Y-%m') AS purchase_month,
       o.order_status,
       COUNT(*) AS item_count,
       COUNT(DISTINCT i.order_id) AS orders_with_items,
       SUM(i.price) AS item_price_total,
       SUM(i.freight_value) AS freight_total,
       SUM(i.price + i.freight_value) AS item_plus_freight_total
FROM FactOrderItem i
JOIN DimOrder o ON o.order_id = i.order_id
GROUP BY DATE_FORMAT(o.order_purchase_timestamp, '%Y-%m'), o.order_status
ORDER BY purchase_month, o.order_status;

-- Q3. What is the distribution of order values calculated from item rows?
-- One row per order is formed before calculating the distribution.
WITH OrderItemTotals AS (
  SELECT order_id,
         SUM(price) AS item_price_total,
         SUM(freight_value) AS freight_total,
         SUM(price + freight_value) AS item_plus_freight_total
  FROM FactOrderItem
  GROUP BY order_id
)
SELECT COUNT(*) AS orders_with_items,
       MIN(item_price_total) AS min_item_price_total,
       AVG(item_price_total) AS avg_item_price_total,
       MAX(item_price_total) AS max_item_price_total,
       MIN(item_plus_freight_total) AS min_item_plus_freight,
       AVG(item_plus_freight_total) AS avg_item_plus_freight,
       MAX(item_plus_freight_total) AS max_item_plus_freight
FROM OrderItemTotals;

-- Q4. How do order and item totals vary by order status?
-- Order counts come from DimOrder; item sums are first summarized by order.
WITH OrderItemTotals AS (
  SELECT order_id, COUNT(*) AS item_count,
         SUM(price) AS item_price_total,
         SUM(freight_value) AS freight_total
  FROM FactOrderItem
  GROUP BY order_id
)
SELECT o.order_status,
       COUNT(*) AS order_count,
       SUM(COALESCE(i.item_count, 0)) AS item_count,
       SUM(COALESCE(i.item_price_total, 0)) AS item_price_total,
       SUM(COALESCE(i.freight_total, 0)) AS freight_total
FROM DimOrder o
LEFT JOIN OrderItemTotals i ON i.order_id = o.order_id
GROUP BY o.order_status
ORDER BY order_count DESC;

/* =====================================================================
   2. CUSTOMER AND SELLER LOGISTICS
   ===================================================================== */

-- Q5. What is the observed delivery-time distribution for delivered orders?
-- Duration is measured from purchase to customer delivery, in days.
SELECT COUNT(*) AS delivered_orders_with_both_dates,
       AVG(TIMESTAMPDIFF(HOUR, order_purchase_timestamp, order_delivered_customer_date) / 24.0) AS avg_delivery_days,
       MIN(TIMESTAMPDIFF(HOUR, order_purchase_timestamp, order_delivered_customer_date) / 24.0) AS min_delivery_days,
       MAX(TIMESTAMPDIFF(HOUR, order_purchase_timestamp, order_delivered_customer_date) / 24.0) AS max_delivery_days
FROM DimOrder
WHERE order_status = 'delivered'
  AND order_delivered_customer_date IS NOT NULL;

-- Q6. What share of delivered orders arrived by the estimated date?
-- Orders missing either date are excluded from the denominator and counted.
SELECT COUNT(*) AS delivered_orders,
       SUM(order_delivered_customer_date IS NOT NULL
           AND order_estimated_delivery_date IS NOT NULL) AS comparable_orders,
       SUM(order_delivered_customer_date <= order_estimated_delivery_date) AS on_or_before_estimate,
       ROUND(100.0 * SUM(order_delivered_customer_date <= order_estimated_delivery_date)
             / NULLIF(SUM(order_delivered_customer_date IS NOT NULL
                          AND order_estimated_delivery_date IS NOT NULL), 0), 2) AS pct_on_or_before_estimate
FROM DimOrder
WHERE order_status = 'delivered';

-- Q7. How do delivered-order timing measures vary by customer state?
-- Order-grain only; no order-item join is used here.
SELECT c.customer_state,
       COUNT(*) AS delivered_orders,
       AVG(TIMESTAMPDIFF(HOUR, o.order_purchase_timestamp, o.order_delivered_customer_date) / 24.0) AS avg_delivery_days,
       AVG(TIMESTAMPDIFF(HOUR, o.order_delivered_carrier_date, o.order_delivered_customer_date) / 24.0) AS avg_carrier_to_customer_days,
       SUM(o.order_delivered_customer_date > o.order_estimated_delivery_date) AS delivered_after_estimate
FROM DimOrder o
JOIN DimCustomer c ON c.customer_id = o.customer_id
WHERE o.order_status = 'delivered'
  AND o.order_delivered_customer_date IS NOT NULL
GROUP BY c.customer_state
ORDER BY delivered_orders DESC;

-- Q8. What item volume, orders, and item/freight totals are associated with sellers by state?
-- Measures are item-grain; each item has exactly one seller.
SELECT s.seller_state,
       COUNT(*) AS item_count,
       COUNT(DISTINCT i.order_id) AS orders_with_seller_items,
       COUNT(DISTINCT s.seller_id) AS sellers_with_items,
       SUM(i.price) AS item_price_total,
       SUM(i.freight_value) AS freight_total
FROM FactOrderItem i
JOIN DimSeller s ON s.seller_id = i.seller_id
GROUP BY s.seller_state
ORDER BY item_count DESC;

-- Q9. How many orders and order rows are associated with each customer state?
SELECT c.customer_state,
       COUNT(*) AS order_rows,
       COUNT(DISTINCT c.customer_unique_id) AS distinct_customer_ids,
       SUM(o.order_status = 'delivered') AS delivered_orders
FROM DimOrder o
JOIN DimCustomer c ON c.customer_id = o.customer_id
GROUP BY c.customer_state
ORDER BY order_rows DESC;

/* =====================================================================
   3. FINANCIALS AND PAYMENT HABITS
   ===================================================================== */

-- Q10. What payment values and record counts appear by payment type?
-- A payment row is one order payment sequence, not one order.
SELECT payment_type,
       COUNT(*) AS payment_rows,
       COUNT(DISTINCT order_id) AS orders_with_payment_type,
       SUM(payment_value) AS payment_value_total,
       AVG(payment_value) AS avg_payment_row_value,
       AVG(payment_installments) AS avg_installments
FROM FactPayment
GROUP BY payment_type
ORDER BY payment_value_total DESC;

-- Q11. What are payment value and payment-row trends by order purchase month?
-- Payments are joined to the order dimension only; item facts are not joined.
SELECT DATE_FORMAT(o.order_purchase_timestamp, '%Y-%m') AS purchase_month,
       COUNT(*) AS payment_rows,
       COUNT(DISTINCT p.order_id) AS orders_with_payments,
       SUM(p.payment_value) AS payment_value_total,
       AVG(p.payment_value) AS avg_payment_row_value
FROM FactPayment p
JOIN DimOrder o ON o.order_id = p.order_id
GROUP BY DATE_FORMAT(o.order_purchase_timestamp, '%Y-%m')
ORDER BY purchase_month;

-- Q12. How many payment records and installments are observed per order?
-- This groups the payment fact to order grain before summarizing.
WITH PaymentByOrder AS (
  SELECT order_id, COUNT(*) AS payment_rows,
         SUM(payment_value) AS total_paid,
         MAX(payment_installments) AS max_installments_recorded
  FROM FactPayment
  GROUP BY order_id
)
SELECT payment_rows,
       COUNT(*) AS order_count,
       AVG(total_paid) AS avg_order_payment_total,
       AVG(max_installments_recorded) AS avg_max_installments
FROM PaymentByOrder
GROUP BY payment_rows
ORDER BY payment_rows;

-- Q13. How do summed payment values compare with summed item price + freight?
-- Each fact is aggregated independently to order grain before comparison.
-- This is a reconciliation comparison, not an assertion that every order
-- should match exactly (source exceptions are retained in DimOrder).
WITH ItemByOrder AS (
  SELECT order_id, SUM(price + freight_value) AS item_plus_freight
  FROM FactOrderItem
  GROUP BY order_id
), PaymentByOrder AS (
  SELECT order_id, SUM(payment_value) AS payment_total
  FROM FactPayment
  GROUP BY order_id
)
SELECT o.reconciliation_status,
       COUNT(*) AS orders_in_status,
       SUM(i.item_plus_freight) AS item_plus_freight_total,
       SUM(p.payment_total) AS payment_total,
       AVG(o.difference) AS avg_source_difference
FROM DimOrder o
LEFT JOIN ItemByOrder i ON i.order_id = o.order_id
LEFT JOIN PaymentByOrder p ON p.order_id = o.order_id
GROUP BY o.reconciliation_status
ORDER BY orders_in_status DESC;

-- Q14. Which order IDs have payment/item totals that differ by more than R$0.01?
-- Separate aggregation prevents many-to-many multiplication.
WITH ItemByOrder AS (
  SELECT order_id, SUM(price + freight_value) AS item_plus_freight
  FROM FactOrderItem
  GROUP BY order_id
), PaymentByOrder AS (
  SELECT order_id, SUM(payment_value) AS payment_total
  FROM FactPayment
  GROUP BY order_id
)
SELECT o.order_id, o.order_status, o.reconciliation_status,
       i.item_plus_freight, p.payment_total,
       ROUND(p.payment_total - i.item_plus_freight, 2) AS calculated_difference,
       o.difference AS source_difference,
       o.dq_financial_exception
FROM DimOrder o
LEFT JOIN ItemByOrder i ON i.order_id = o.order_id
LEFT JOIN PaymentByOrder p ON p.order_id = o.order_id
WHERE i.item_plus_freight IS NOT NULL
  AND p.payment_total IS NOT NULL
  AND ABS(p.payment_total - i.item_plus_freight) > 0.01
ORDER BY ABS(p.payment_total - i.item_plus_freight) DESC;

/* =====================================================================
   4. PRODUCT AND CATEGORY PERFORMANCE
   ===================================================================== */

-- Q15. Which translated product categories have the most item rows and value?
-- English category is already attached to DimProduct; untranslated categories
-- remain visible as 'Unknown / Untranslated'.
SELECT p.product_category_name_english,
       COUNT(*) AS item_count,
       COUNT(DISTINCT i.order_id) AS orders_with_category,
       COUNT(DISTINCT i.product_id) AS distinct_products,
       SUM(i.price) AS item_price_total,
       SUM(i.freight_value) AS freight_total,
       AVG(i.price) AS avg_item_price
FROM FactOrderItem i
JOIN DimProduct p ON p.product_id = i.product_id
GROUP BY p.product_category_name_english
ORDER BY item_price_total DESC;

-- Q16. Which individual products have the most units, orders, and item value?
SELECT p.product_id,
       p.product_category_name_english,
       COUNT(*) AS units_or_item_rows,
       COUNT(DISTINCT i.order_id) AS distinct_orders,
       SUM(i.price) AS item_price_total,
       AVG(i.price) AS avg_item_price
FROM FactOrderItem i
JOIN DimProduct p ON p.product_id = i.product_id
GROUP BY p.product_id, p.product_category_name_english
ORDER BY item_price_total DESC
LIMIT 25;

-- Q17. How are item prices and freight distributed across categories?
SELECT p.product_category_name_english,
       COUNT(*) AS item_count,
       MIN(i.price) AS min_item_price,
       AVG(i.price) AS avg_item_price,
       MAX(i.price) AS max_item_price,
       AVG(i.freight_value) AS avg_freight_per_item,
       MAX(i.freight_value) AS max_freight_per_item
FROM FactOrderItem i
JOIN DimProduct p ON p.product_id = i.product_id
GROUP BY p.product_category_name_english
ORDER BY item_count DESC;

-- Q18. How many products have missing or invalid product attributes?
SELECT dq_missing_attributes, dq_invalid_weight,
       COUNT(*) AS product_count
FROM DimProduct
GROUP BY dq_missing_attributes, dq_invalid_weight
ORDER BY dq_missing_attributes DESC, dq_invalid_weight DESC;

/* =====================================================================
   5. CRITICAL DATA INTEGRITY AND CLEANING CHECKS
   ===================================================================== */

-- Q19. What are the loaded row counts for all model tables?
SELECT 'DimCustomer' AS table_name, COUNT(*) AS row_count FROM DimCustomer
UNION ALL SELECT 'DimSeller', COUNT(*) FROM DimSeller
UNION ALL SELECT 'DimProduct', COUNT(*) FROM DimProduct
UNION ALL SELECT 'DimOrder', COUNT(*) FROM DimOrder
UNION ALL SELECT 'DimDate', COUNT(*) FROM DimDate
UNION ALL SELECT 'FactOrderItem', COUNT(*) FROM FactOrderItem
UNION ALL SELECT 'FactPayment', COUNT(*) FROM FactPayment
UNION ALL SELECT 'FactReview', COUNT(*) FROM FactReview;

-- Q20. Are natural keys unique at the declared grains?
-- These queries should return zero rows for item and payment facts.
SELECT order_id, order_item_id, COUNT(*) AS duplicate_rows
FROM FactOrderItem
GROUP BY order_id, order_item_id
HAVING COUNT(*) > 1;

SELECT order_id, payment_sequential, COUNT(*) AS duplicate_rows
FROM FactPayment
GROUP BY order_id, payment_sequential
HAVING COUNT(*) > 1;

-- Source review_id and order_id are intentionally not unique in FactReview.
-- How many repeated source review IDs and orders have multiple review rows?
SELECT COUNT(*) AS repeated_review_id_groups
FROM (
  SELECT review_id FROM FactReview GROUP BY review_id HAVING COUNT(*) > 1
) repeated_ids;

SELECT COUNT(*) AS orders_with_multiple_review_rows,
       MAX(review_rows) AS max_review_rows_for_one_order
FROM (
  SELECT order_id, COUNT(*) AS review_rows
  FROM FactReview
  GROUP BY order_id
  HAVING COUNT(*) > 1
) repeated_order_reviews;

-- Q21. Are any required foreign-key relationships missing?
-- These counts should be zero; enforced foreign keys also reject such loads.
SELECT 'order_without_customer' AS check_name, COUNT(*) AS issue_count
FROM DimOrder o LEFT JOIN DimCustomer c ON c.customer_id=o.customer_id
WHERE c.customer_id IS NULL
UNION ALL
SELECT 'item_without_order', COUNT(*)
FROM FactOrderItem i LEFT JOIN DimOrder o ON o.order_id=i.order_id
WHERE o.order_id IS NULL
UNION ALL
SELECT 'item_without_product', COUNT(*)
FROM FactOrderItem i LEFT JOIN DimProduct p ON p.product_id=i.product_id
WHERE p.product_id IS NULL
UNION ALL
SELECT 'item_without_seller', COUNT(*)
FROM FactOrderItem i LEFT JOIN DimSeller s ON s.seller_id=i.seller_id
WHERE s.seller_id IS NULL
UNION ALL
SELECT 'payment_without_order', COUNT(*)
FROM FactPayment p LEFT JOIN DimOrder o ON o.order_id=p.order_id
WHERE o.order_id IS NULL
UNION ALL
SELECT 'review_without_order', COUNT(*)
FROM FactReview r LEFT JOIN DimOrder o ON o.order_id=r.order_id
WHERE o.order_id IS NULL;

-- Q22. What source quality flags and order reconciliation categories remain?
SELECT reconciliation_status,
       dq_missing_delivery_date,
       dq_canceled_but_delivered,
       dq_financial_exception,
       COUNT(*) AS order_count
FROM DimOrder
GROUP BY reconciliation_status, dq_missing_delivery_date,
         dq_canceled_but_delivered, dq_financial_exception
ORDER BY order_count DESC;

-- Q23. How many optional dates and descriptive fields remain blank?
SELECT 'approved_timestamp_missing' AS issue_name, COUNT(*) AS row_count
FROM DimOrder WHERE order_approved_at IS NULL
UNION ALL SELECT 'carrier_timestamp_missing', COUNT(*) FROM DimOrder WHERE order_delivered_carrier_date IS NULL
UNION ALL SELECT 'customer_delivery_timestamp_missing', COUNT(*) FROM DimOrder WHERE order_delivered_customer_date IS NULL
UNION ALL SELECT 'estimated_delivery_timestamp_missing', COUNT(*) FROM DimOrder WHERE order_estimated_delivery_date IS NULL
UNION ALL SELECT 'review_title_missing', COUNT(*) FROM FactReview WHERE review_comment_title IS NULL
UNION ALL SELECT 'review_message_missing', COUNT(*) FROM FactReview WHERE review_comment_message IS NULL
UNION ALL SELECT 'product_category_untranslated', COUNT(*) FROM DimProduct WHERE product_category_name_english='Unknown / Untranslated';

-- Q24. Which orders have no item, payment, or review records?
-- These are record-coverage checks; absence does not by itself imply an error.
SELECT COUNT(*) AS orders_without_items
FROM DimOrder o LEFT JOIN FactOrderItem i ON i.order_id=o.order_id
WHERE i.order_id IS NULL;

SELECT COUNT(*) AS orders_without_payment_rows
FROM DimOrder o LEFT JOIN FactPayment p ON p.order_id=o.order_id
WHERE p.order_id IS NULL;

SELECT COUNT(*) AS orders_without_review_rows
FROM DimOrder o LEFT JOIN FactReview r ON r.order_id=o.order_id
WHERE r.order_id IS NULL;

-- Q25. What is the review score distribution and comment availability?
SELECT review_score,
       COUNT(*) AS review_rows,
       SUM(review_comment_title IS NOT NULL) AS rows_with_title,
       SUM(review_comment_message IS NOT NULL) AS rows_with_message
FROM FactReview
GROUP BY review_score
ORDER BY review_score;

/* End of descriptive EDA query pack. */
