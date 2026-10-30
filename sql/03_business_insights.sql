/*
  Olist e-commerce analytics — business insight query pack
  MySQL 8.0.16+ | Requires olist_mysql_data_loading.sql to be run first.

  This file quantifies customer retention, logistics, seller performance,
  cancellation exposure, and category performance. It is descriptive and does
  not establish causes.

  Measurement limits:
  - Customer value is historical delivered item value, not predictive CLV.
  - Canceled/unavailable item value is exposure, not confirmed financial loss.
  - No cost of goods or operating costs are provided, so true margins cannot
    be calculated. Freight/value ratio is a logistics burden proxy only.
  - Keep FactOrderItem, FactPayment, and FactReview at separate grains. When
    comparing facts, aggregate each to order grain before joining.
*/

/* =====================================================================
   1. CUSTOMER LIFETIME VALUE PROXY AND RETENTION
   ===================================================================== */

-- Q1. Which customers have the highest observed delivered-order value?
WITH ItemByOrder AS (
  SELECT order_id, SUM(price) AS item_value, SUM(freight_value) AS freight_value
  FROM FactOrderItem GROUP BY order_id
), CustomerOrder AS (
  SELECT c.customer_unique_id, o.order_id, o.order_purchase_timestamp,
         COALESCE(i.item_value, 0) AS item_value,
         COALESCE(i.freight_value, 0) AS freight_value,
         (i.order_id IS NOT NULL) AS has_item_row
  FROM DimOrder o
  JOIN DimCustomer c ON c.customer_id=o.customer_id
  LEFT JOIN ItemByOrder i ON i.order_id=o.order_id
  WHERE o.order_status='delivered'
)
SELECT customer_unique_id, COUNT(*) AS delivered_orders,
       SUM(has_item_row) AS delivered_orders_with_item_rows,
       MIN(order_purchase_timestamp) AS first_observed_order,
       MAX(order_purchase_timestamp) AS most_recent_observed_order,
       SUM(item_value) AS observed_item_value,
       SUM(freight_value) AS associated_freight_value,
       AVG(item_value) AS avg_item_value_per_order,
       (COUNT(*) > 1) AS repeat_buyer_flag
FROM CustomerOrder
GROUP BY customer_unique_id
ORDER BY observed_item_value DESC
LIMIT 100;

-- Q2. What proportion of customers made more than one delivered order?
WITH OrdersPerCustomer AS (
  SELECT c.customer_unique_id, COUNT(*) AS order_count
  FROM DimOrder o JOIN DimCustomer c ON c.customer_id=o.customer_id
  WHERE o.order_status='delivered'
  GROUP BY c.customer_unique_id
)
SELECT COUNT(*) AS observed_customers,
       SUM(order_count > 1) AS repeat_customers,
       ROUND(100.0*SUM(order_count > 1)/NULLIF(COUNT(*),0),2) AS repeat_customer_pct,
       AVG(order_count) AS avg_delivered_orders_per_customer,
       MAX(order_count) AS max_delivered_orders_per_customer
FROM OrdersPerCustomer;

-- Q3. What does delivered-order retention look like by first-order cohort?
-- Month 0 is each customer's first delivered-order month in this dataset.
WITH CustomerActivity AS (
  SELECT DISTINCT c.customer_unique_id,
         STR_TO_DATE(DATE_FORMAT(o.order_purchase_timestamp,'%Y-%m-01'),'%Y-%m-%d') AS activity_month
  FROM DimOrder o JOIN DimCustomer c ON c.customer_id=o.customer_id
  WHERE o.order_status='delivered'
), CustomerCohort AS (
  SELECT customer_unique_id, MIN(activity_month) AS cohort_month
  FROM CustomerActivity GROUP BY customer_unique_id
), CohortSizes AS (
  SELECT cohort_month, COUNT(*) AS cohort_size
  FROM CustomerCohort GROUP BY cohort_month
)
SELECT cc.cohort_month,
       TIMESTAMPDIFF(MONTH,cc.cohort_month,ca.activity_month) AS months_since_first,
       cs.cohort_size,
       COUNT(DISTINCT cc.customer_unique_id) AS active_customers,
       ROUND(100.0*COUNT(DISTINCT cc.customer_unique_id)/NULLIF(cs.cohort_size,0),2) AS retained_customer_pct
FROM CustomerCohort cc
JOIN CustomerActivity ca ON ca.customer_unique_id=cc.customer_unique_id
JOIN CohortSizes cs ON cs.cohort_month=cc.cohort_month
GROUP BY cc.cohort_month, months_since_first, cs.cohort_size
ORDER BY cc.cohort_month, months_since_first;

/* =====================================================================
   2. SHIPPING AND LOGISTICS OPTIMIZATION
   ===================================================================== */

-- Q4. Which customer states have the highest delivered-order lateness?
-- Only delivered orders with both actual and estimated dates enter the
-- on-time/late denominator; delivered orders are still counted separately.
SELECT c.customer_state, COUNT(*) AS delivered_orders,
       SUM(o.order_delivered_customer_date IS NOT NULL AND o.order_estimated_delivery_date IS NOT NULL) AS comparable_orders,
       SUM(o.order_delivered_customer_date>o.order_estimated_delivery_date) AS late_orders,
       ROUND(100.0*SUM(o.order_delivered_customer_date>o.order_estimated_delivery_date)
         /NULLIF(SUM(o.order_delivered_customer_date IS NOT NULL AND o.order_estimated_delivery_date IS NOT NULL),0),2) AS late_order_pct,
       AVG(TIMESTAMPDIFF(HOUR,o.order_purchase_timestamp,o.order_delivered_customer_date)/24.0) AS avg_delivery_days,
       AVG(CASE WHEN o.order_delivered_customer_date>o.order_estimated_delivery_date
         THEN TIMESTAMPDIFF(HOUR,o.order_estimated_delivery_date,o.order_delivered_customer_date)/24.0 END) AS avg_days_late
FROM DimOrder o JOIN DimCustomer c ON c.customer_id=o.customer_id
WHERE o.order_status='delivered'
GROUP BY c.customer_state
ORDER BY late_order_pct DESC, comparable_orders DESC;

-- Q5. How much delivery time is spent before and after carrier handoff?
SELECT COUNT(*) AS delivered_orders_with_all_timestamps,
       AVG(TIMESTAMPDIFF(HOUR,order_purchase_timestamp,order_delivered_carrier_date)/24.0) AS avg_purchase_to_carrier_days,
       AVG(TIMESTAMPDIFF(HOUR,order_delivered_carrier_date,order_delivered_customer_date)/24.0) AS avg_carrier_to_customer_days,
       AVG(TIMESTAMPDIFF(HOUR,order_purchase_timestamp,order_delivered_customer_date)/24.0) AS avg_total_delivery_days
FROM DimOrder
WHERE order_status='delivered'
  AND order_delivered_carrier_date IS NOT NULL
  AND order_delivered_customer_date IS NOT NULL;

/* =====================================================================
   3. SELLER PERFORMANCE AND HEALTH
   ===================================================================== */

-- Q6. How do sellers compare on delivered, late, canceled/unavailable orders
-- and associated item value? Each seller-order pair counts only once.
WITH SellerOrder AS (
  SELECT DISTINCT seller_id, order_id FROM FactOrderItem
), SellerItemValue AS (
  SELECT seller_id, COUNT(*) AS item_rows, SUM(price) AS item_price_value,
         SUM(freight_value) AS freight_value
  FROM FactOrderItem GROUP BY seller_id
), SellerOrderStats AS (
  SELECT so.seller_id, COUNT(*) AS orders_with_items,
         SUM(o.order_status='delivered') AS delivered_orders,
         SUM(o.order_status IN ('canceled','unavailable')) AS canceled_or_unavailable_orders,
         SUM(o.order_status='delivered' AND o.order_delivered_customer_date IS NOT NULL
             AND o.order_estimated_delivery_date IS NOT NULL
             AND o.order_delivered_customer_date>o.order_estimated_delivery_date) AS late_delivered_orders,
         AVG(CASE WHEN o.order_status='delivered' AND o.order_delivered_customer_date IS NOT NULL
             THEN TIMESTAMPDIFF(HOUR,o.order_purchase_timestamp,o.order_delivered_customer_date)/24.0 END) AS avg_delivery_days
  FROM SellerOrder so JOIN DimOrder o ON o.order_id=so.order_id
  GROUP BY so.seller_id
)
SELECT s.seller_id, s.seller_state, s.seller_city, v.item_rows,
       st.orders_with_items, st.delivered_orders,
       ROUND(100.0*st.delivered_orders/NULLIF(st.orders_with_items,0),2) AS delivered_order_pct,
       st.canceled_or_unavailable_orders,
       ROUND(100.0*st.canceled_or_unavailable_orders/NULLIF(st.orders_with_items,0),2) AS canceled_or_unavailable_pct,
       st.late_delivered_orders, st.avg_delivery_days,
       v.item_price_value, v.freight_value
FROM SellerOrderStats st
JOIN DimSeller s ON s.seller_id=st.seller_id
JOIN SellerItemValue v ON v.seller_id=st.seller_id
ORDER BY canceled_or_unavailable_pct DESC, orders_with_items DESC;

/* =====================================================================
   4. CANCELED / UNAVAILABLE ORDER FINANCIAL EXPOSURE
   ===================================================================== */

-- Q7. What item value and recorded payment value are associated with
-- canceled and unavailable orders? These are exposure measures, not losses.
WITH ItemByOrder AS (
  SELECT order_id, SUM(price) AS item_price_value, SUM(freight_value) AS freight_value,
         SUM(price+freight_value) AS item_plus_freight_value
  FROM FactOrderItem GROUP BY order_id
), PaymentByOrder AS (
  SELECT order_id, SUM(payment_value) AS recorded_payment_value
  FROM FactPayment GROUP BY order_id
)
SELECT o.order_status, COUNT(*) AS order_count,
       SUM(i.order_id IS NOT NULL) AS orders_with_item_rows,
       SUM(COALESCE(i.item_price_value,0)) AS item_price_exposure,
       SUM(COALESCE(i.freight_value,0)) AS associated_freight_value,
       SUM(COALESCE(i.item_plus_freight_value,0)) AS item_plus_freight_exposure,
       SUM(COALESCE(p.recorded_payment_value,0)) AS recorded_payment_value,
       SUM(p.order_id IS NOT NULL) AS orders_with_payment_rows
FROM DimOrder o
LEFT JOIN ItemByOrder i ON i.order_id=o.order_id
LEFT JOIN PaymentByOrder p ON p.order_id=o.order_id
WHERE o.order_status IN ('canceled','unavailable')
GROUP BY o.order_status;

-- Q8. Which canceled/unavailable orders have item rows or recorded payments?
-- This list supports review; payment records do not prove refund failure.
WITH ItemByOrder AS (
  SELECT order_id,SUM(price+freight_value) AS item_plus_freight_value
  FROM FactOrderItem GROUP BY order_id
), PaymentByOrder AS (
  SELECT order_id,SUM(payment_value) AS recorded_payment_value
  FROM FactPayment GROUP BY order_id
)
SELECT o.order_id,o.order_status,o.reconciliation_status,
       i.item_plus_freight_value,p.recorded_payment_value,
       o.dq_financial_exception,o.difference
FROM DimOrder o
LEFT JOIN ItemByOrder i ON i.order_id=o.order_id
LEFT JOIN PaymentByOrder p ON p.order_id=o.order_id
WHERE o.order_status IN ('canceled','unavailable')
  AND (i.order_id IS NOT NULL OR p.order_id IS NOT NULL)
ORDER BY o.order_status,p.recorded_payment_value DESC;

/* =====================================================================
   5. PRODUCT CATEGORY VOLUME AND MARGIN PROXY
   ===================================================================== */

-- Q9. Which delivered-item categories are high-volume with lower freight
-- burden, or low-volume with higher freight burden?
-- Relative quartiles use the category groups returned by the model. Freight
-- burden is freight/item price, NOT margin. COGS and other costs are absent.
WITH CategoryMetrics AS (
  SELECT p.product_category_name_english,
         COUNT(*) AS item_count, COUNT(DISTINCT i.order_id) AS order_count,
         COUNT(DISTINCT i.product_id) AS product_count,
         SUM(i.price) AS item_price_value, SUM(i.freight_value) AS freight_value,
         AVG(i.price) AS avg_item_price,
         SUM(i.freight_value)/NULLIF(SUM(i.price),0) AS freight_to_item_value_ratio
  FROM FactOrderItem i
  JOIN DimProduct p ON p.product_id=i.product_id
  JOIN DimOrder o ON o.order_id=i.order_id
  WHERE o.order_status='delivered'
  GROUP BY p.product_category_name_english
), CategoryQuartiles AS (
  SELECT cm.*,
         NTILE(4) OVER (ORDER BY item_count) AS volume_quartile,
         NTILE(4) OVER (ORDER BY freight_to_item_value_ratio) AS freight_burden_quartile
  FROM CategoryMetrics cm
)
SELECT product_category_name_english,item_count,order_count,product_count,
       item_price_value,freight_value,avg_item_price,freight_to_item_value_ratio,
       volume_quartile,freight_burden_quartile,
       CASE WHEN volume_quartile=4 AND freight_burden_quartile=1 THEN 'High volume / low freight burden'
            WHEN volume_quartile=1 AND freight_burden_quartile=4 THEN 'Low volume / high freight burden'
            ELSE 'Other relative category profile' END AS category_profile
FROM CategoryQuartiles
ORDER BY volume_quartile DESC,freight_burden_quartile,item_count DESC;

-- Q10. How do categories rank separately by delivered item value and volume?
SELECT p.product_category_name_english,
       COUNT(*) AS delivered_item_count,
       COUNT(DISTINCT i.order_id) AS delivered_order_count,
       SUM(i.price) AS delivered_item_price_value,
       SUM(i.freight_value) AS freight_value,
       AVG(i.price) AS avg_item_price,
       SUM(i.freight_value)/NULLIF(SUM(i.price),0) AS freight_to_item_value_ratio
FROM FactOrderItem i
JOIN DimProduct p ON p.product_id=i.product_id
JOIN DimOrder o ON o.order_id=i.order_id
WHERE o.order_status='delivered'
GROUP BY p.product_category_name_english
ORDER BY delivered_item_price_value DESC;

/* =====================================================================
   CONCLUSION & NEXT STEPS (FOR POWER BI DASHBOARDING)
   =====================================================================

   1. DATA TRANSFORMATION COMPLETED
      The cleaned source files are organized into an 8-table dimensional
      model: five dimensions and three separate facts for order items,
      payments, and reviews. English categories are attached to DimProduct;
      selected ZIP/geolocation fields are excluded; reconciliation and
      data-quality flags are retained.

   2. CRITICAL BUSINESS INSIGHTS IDENTIFIED
      The analysis quantifies delivered customer value and repeat activity,
      delivery timing and lateness, seller order outcomes, canceled/unavailable
      order-value exposure, and category volume and freight burden. Customer
      value is historical; cancellation exposure is not confirmed loss; and
      true category margin cannot be measured without product cost data.

   3. POWER BI TRANSITION
      Connect to the eight model tables and create dimension-to-fact
      relationships. Build focused pages for Customer & Retention,
      Logistics & Seller Health, Financial Exposure, and Product Categories.
      Keep measures at their source fact grain and validate report totals
      against these SQL results before publishing.
*/
