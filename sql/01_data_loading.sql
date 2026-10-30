/*
  Olist e-commerce analytics — MySQL 8 loading script
  ==================================================
  Model: 5 dimensions + 3 separate facts.
  Fact grains: one row per order item; one row per payment sequence;
  one row per source review row. This prevents item/payment/review fan-out.

*/

-- Configure LOCAL INFILE in MySQL client/server if needed; do not change global settings here.

-- Safety: never drop an existing database in this portfolio script.
CREATE DATABASE IF NOT EXISTS olist_analysis;
USE olist_analysis;
SET NAMES utf8mb4;

/* ---------- 1. Temporary raw staging tables ----------
   Stage strings first so empty CSV cells can be converted deliberately. */
/* Clear this session's staging copies before a re-import. These are temporary only. */
DROP TEMPORARY TABLE IF EXISTS stg_customers, stg_sellers, stg_products,
  stg_category_translation, stg_orders, stg_order_items, stg_order_payments,
  stg_order_reviews;

CREATE TEMPORARY TABLE stg_customers (
 customer_id VARCHAR(64), customer_unique_id VARCHAR(64), customer_zip_code_prefix VARCHAR(16), customer_city VARCHAR(200), customer_state VARCHAR(8)
) CHARACTER SET utf8mb4;
CREATE TEMPORARY TABLE stg_sellers (
 seller_id VARCHAR(64), seller_zip_code_prefix VARCHAR(16), seller_city VARCHAR(200), seller_state VARCHAR(8)
) CHARACTER SET utf8mb4;
CREATE TEMPORARY TABLE stg_products (
 product_id VARCHAR(64), product_category_name VARCHAR(200), product_name_lenght VARCHAR(32), product_description_lenght VARCHAR(32), product_photos_qty VARCHAR(32), product_weight_g VARCHAR(32), product_length_cm VARCHAR(32), product_height_cm VARCHAR(32), product_width_cm VARCHAR(32), dq_missing_attributes VARCHAR(16), dq_invalid_weight VARCHAR(16)
) CHARACTER SET utf8mb4;
CREATE TEMPORARY TABLE stg_category_translation (
 product_category_name VARCHAR(200), product_category_name_english VARCHAR(200)
) CHARACTER SET utf8mb4;
CREATE TEMPORARY TABLE stg_orders (
 order_id VARCHAR(64), customer_id VARCHAR(64), order_status VARCHAR(32), order_purchase_timestamp VARCHAR(40), order_approved_at VARCHAR(40), order_delivered_carrier_date VARCHAR(40), order_delivered_customer_date VARCHAR(40), order_estimated_delivery_date VARCHAR(40), dq_missing_delivery_date VARCHAR(16), dq_canceled_but_delivered VARCHAR(16), reconciliation_status VARCHAR(40), difference VARCHAR(40), dq_financial_exception VARCHAR(16)
) CHARACTER SET utf8mb4;
CREATE TEMPORARY TABLE stg_order_items (
 order_id VARCHAR(64), order_item_id VARCHAR(16), product_id VARCHAR(64), seller_id VARCHAR(64), shipping_limit_date VARCHAR(40), price VARCHAR(40), freight_value VARCHAR(40)
) CHARACTER SET utf8mb4;
CREATE TEMPORARY TABLE stg_order_payments (
 order_id VARCHAR(64), payment_sequential VARCHAR(16), payment_type VARCHAR(32), payment_installments VARCHAR(16), payment_value VARCHAR(40)
) CHARACTER SET utf8mb4;
CREATE TEMPORARY TABLE stg_order_reviews (
 review_id VARCHAR(64), order_id VARCHAR(64), review_score VARCHAR(16), review_comment_title TEXT, review_comment_message LONGTEXT, review_creation_date VARCHAR(40), review_answer_timestamp VARCHAR(40)
) CHARACTER SET utf8mb4;

/* CSV import: headers are skipped; fields are quoted where necessary.
   The Portuguese product category is staged only to look up its English label. */
LOAD DATA LOCAL INFILE '/REPLACE_WITH_ABSOLUTE_PATH_TO_CLEANED_DATA/customers_cleaned.csv' INTO TABLE stg_customers CHARACTER SET utf8mb4
 FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"'
 LINES TERMINATED BY '\r\n' IGNORE 1 LINES;
LOAD DATA LOCAL INFILE '/REPLACE_WITH_ABSOLUTE_PATH_TO_CLEANED_DATA/sellers_cleaned.csv' INTO TABLE stg_sellers CHARACTER SET utf8mb4
 FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"'
 LINES TERMINATED BY '\r\n' IGNORE 1 LINES;
LOAD DATA LOCAL INFILE '/REPLACE_WITH_ABSOLUTE_PATH_TO_CLEANED_DATA/products_cleaned.csv' INTO TABLE stg_products CHARACTER SET utf8mb4
 FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"'
 LINES TERMINATED BY '\r\n' IGNORE 1 LINES;
LOAD DATA LOCAL INFILE '/REPLACE_WITH_ABSOLUTE_PATH_TO_CLEANED_DATA/product_category_name_translation_cleaned.csv' INTO TABLE stg_category_translation CHARACTER SET utf8mb4
 FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"'
 LINES TERMINATED BY '\r\n' IGNORE 1 LINES;
LOAD DATA LOCAL INFILE '/REPLACE_WITH_ABSOLUTE_PATH_TO_CLEANED_DATA/orders_cleaned.csv' INTO TABLE stg_orders CHARACTER SET utf8mb4
 FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"'
 LINES TERMINATED BY '\r\n' IGNORE 1 LINES;
LOAD DATA LOCAL INFILE '/REPLACE_WITH_ABSOLUTE_PATH_TO_CLEANED_DATA/order_items_cleaned.csv' INTO TABLE stg_order_items CHARACTER SET utf8mb4
 FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"'
 LINES TERMINATED BY '\r\n' IGNORE 1 LINES;
LOAD DATA LOCAL INFILE '/REPLACE_WITH_ABSOLUTE_PATH_TO_CLEANED_DATA/order_payments_cleaned.csv' INTO TABLE stg_order_payments CHARACTER SET utf8mb4
 FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"'
 LINES TERMINATED BY '\r\n' IGNORE 1 LINES;
LOAD DATA LOCAL INFILE '/REPLACE_WITH_ABSOLUTE_PATH_TO_CLEANED_DATA/order_reviews_cleaned.csv' INTO TABLE stg_order_reviews CHARACTER SET utf8mb4
 FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '"'
 LINES TERMINATED BY '\r\n' IGNORE 1 LINES;

/* Review import counts before loading the model. Expected row counts are
   customers 99,441; sellers 3,095; products 32,951; orders 99,441;
   items 112,650; payments 103,886; reviews 99,224; translations 71. */
SELECT 'customers' AS staging_table, COUNT(*) AS rows_loaded FROM stg_customers
UNION ALL SELECT 'sellers', COUNT(*) FROM stg_sellers
UNION ALL SELECT 'products', COUNT(*) FROM stg_products
UNION ALL SELECT 'category_translation', COUNT(*) FROM stg_category_translation
UNION ALL SELECT 'orders', COUNT(*) FROM stg_orders
UNION ALL SELECT 'order_items', COUNT(*) FROM stg_order_items
UNION ALL SELECT 'order_payments', COUNT(*) FROM stg_order_payments
UNION ALL SELECT 'order_reviews', COUNT(*) FROM stg_order_reviews;

/* ---------- 2. Final dimensional tables ---------- */
  
CREATE TABLE DimCustomer (
 customer_id CHAR(32) NOT NULL,
 customer_unique_id CHAR(32) NOT NULL,
 customer_city VARCHAR(200) NOT NULL,
 customer_state CHAR(2) NOT NULL,
 PRIMARY KEY (customer_id),
 KEY ix_DimCustomer_unique_id (customer_unique_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE DimSeller (
 seller_id CHAR(32) NOT NULL,
 seller_city VARCHAR(200) NOT NULL,
 seller_state CHAR(2) NOT NULL,
 PRIMARY KEY (seller_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE DimProduct (
 product_id CHAR(32) NOT NULL,
 product_category_name_english VARCHAR(200) NOT NULL,
 product_name_lenght SMALLINT NULL,
 product_description_lenght INT NULL,
 product_photos_qty SMALLINT NULL,
 product_weight_g DECIMAL(12,2) NULL,
 product_length_cm DECIMAL(12,2) NULL,
 product_height_cm DECIMAL(12,2) NULL,
 product_width_cm DECIMAL(12,2) NULL,
 dq_missing_attributes BOOLEAN NOT NULL,
 dq_invalid_weight BOOLEAN NOT NULL,
 PRIMARY KEY (product_id),
 KEY ix_DimProduct_category (product_category_name_english)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE DimDate (
 date_key INT NOT NULL,
 full_date DATE NOT NULL,
 `year` SMALLINT NOT NULL,
 `quarter` TINYINT NOT NULL,
 `month` TINYINT NOT NULL,
 month_name VARCHAR(12) NOT NULL,
 `day` TINYINT NOT NULL,
 day_of_week TINYINT NOT NULL COMMENT 'Monday=1 through Sunday=7',
 PRIMARY KEY (date_key),
 UNIQUE KEY uq_DimDate_full_date (full_date)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE DimOrder (
 order_id CHAR(32) NOT NULL,
 customer_id CHAR(32) NOT NULL,
 order_status VARCHAR(32) NOT NULL,
 order_purchase_timestamp DATETIME NULL,
 purchase_date_key INT NOT NULL,
 order_approved_at DATETIME NULL,
 approved_date_key INT NOT NULL,
 order_delivered_carrier_date DATETIME NULL,
 delivered_carrier_date_key INT NOT NULL,
 order_delivered_customer_date DATETIME NULL,
 delivered_customer_date_key INT NOT NULL,
 order_estimated_delivery_date DATETIME NULL,
 estimated_delivery_date_key INT NOT NULL,
 dq_missing_delivery_date BOOLEAN NOT NULL,
 dq_canceled_but_delivered BOOLEAN NOT NULL,
 reconciliation_status VARCHAR(40) NULL,
 difference DECIMAL(12,2) NULL,
 dq_financial_exception BOOLEAN NOT NULL,
 PRIMARY KEY (order_id),
 KEY ix_DimOrder_customer (customer_id),
 KEY ix_DimOrder_status (order_status),
 CONSTRAINT fk_DimOrder_Customer FOREIGN KEY (customer_id) REFERENCES DimCustomer(customer_id),
 CONSTRAINT fk_DimOrder_PurchaseDate FOREIGN KEY (purchase_date_key) REFERENCES DimDate(date_key),
 CONSTRAINT fk_DimOrder_ApprovedDate FOREIGN KEY (approved_date_key) REFERENCES DimDate(date_key),
 CONSTRAINT fk_DimOrder_CarrierDate FOREIGN KEY (delivered_carrier_date_key) REFERENCES DimDate(date_key),
 CONSTRAINT fk_DimOrder_DeliveredDate FOREIGN KEY (delivered_customer_date_key) REFERENCES DimDate(date_key),
 CONSTRAINT fk_DimOrder_EstimatedDate FOREIGN KEY (estimated_delivery_date_key) REFERENCES DimDate(date_key)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE FactOrderItem (
 order_id CHAR(32) NOT NULL,
 order_item_id SMALLINT NOT NULL,
 product_id CHAR(32) NOT NULL,
 seller_id CHAR(32) NOT NULL,
 shipping_limit_date DATETIME NULL,
 shipping_limit_date_key INT NOT NULL,
 price DECIMAL(12,2) NOT NULL,
 freight_value DECIMAL(12,2) NOT NULL,
 PRIMARY KEY (order_id, order_item_id),
 KEY ix_FactOrderItem_product (product_id),
 KEY ix_FactOrderItem_seller (seller_id),
 CONSTRAINT fk_FactOrderItem_Order FOREIGN KEY (order_id) REFERENCES DimOrder(order_id),
 CONSTRAINT fk_FactOrderItem_Product FOREIGN KEY (product_id) REFERENCES DimProduct(product_id),
 CONSTRAINT fk_FactOrderItem_Seller FOREIGN KEY (seller_id) REFERENCES DimSeller(seller_id),
 CONSTRAINT fk_FactOrderItem_Date FOREIGN KEY (shipping_limit_date_key) REFERENCES DimDate(date_key),
 CONSTRAINT ck_FactOrderItem_amounts CHECK (price >= 0 AND freight_value >= 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE FactPayment (
 order_id CHAR(32) NOT NULL,
 payment_sequential SMALLINT NOT NULL,
 payment_type VARCHAR(32) NOT NULL,
 payment_installments SMALLINT NOT NULL,
 payment_value DECIMAL(12,2) NOT NULL,
 PRIMARY KEY (order_id, payment_sequential),
 KEY ix_FactPayment_type (payment_type),
 CONSTRAINT fk_FactPayment_Order FOREIGN KEY (order_id) REFERENCES DimOrder(order_id),
 CONSTRAINT ck_FactPayment_amounts CHECK (payment_installments >= 0 AND payment_value >= 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE FactReview (
 review_row_key BIGINT NOT NULL AUTO_INCREMENT,
 review_id CHAR(32) NOT NULL COMMENT 'Source review_id is not unique; retain it for traceability',
 order_id CHAR(32) NOT NULL,
 review_score TINYINT NOT NULL,
 review_creation_date DATETIME NULL,
 review_creation_date_key INT NOT NULL,
 review_answer_timestamp DATETIME NULL,
 review_answer_date_key INT NOT NULL,
 review_comment_title TEXT NULL,
 review_comment_message LONGTEXT NULL,
 PRIMARY KEY (review_row_key),
 KEY ix_FactReview_source_review (review_id),
 KEY ix_FactReview_order (order_id),
 CONSTRAINT fk_FactReview_Order FOREIGN KEY (order_id) REFERENCES DimOrder(order_id),
 CONSTRAINT fk_FactReview_CreationDate FOREIGN KEY (review_creation_date_key) REFERENCES DimDate(date_key),
 CONSTRAINT fk_FactReview_AnswerDate FOREIGN KEY (review_answer_date_key) REFERENCES DimDate(date_key),
 CONSTRAINT ck_FactReview_score CHECK (review_score BETWEEN 1 AND 5)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

/* ---------- 3. Transform and load ---------- */
START TRANSACTION;

INSERT INTO DimCustomer (customer_id, customer_unique_id, customer_city, customer_state)
SELECT customer_id, customer_unique_id, customer_city, customer_state FROM stg_customers;

INSERT INTO DimSeller (seller_id, seller_city, seller_state)
SELECT seller_id, seller_city, seller_state FROM stg_sellers;

INSERT INTO DimProduct (
 product_id, product_category_name_english, product_name_lenght, product_description_lenght,
 product_photos_qty, product_weight_g, product_length_cm, product_height_cm, product_width_cm,
 dq_missing_attributes, dq_invalid_weight
)
SELECT p.product_id,
       COALESCE(NULLIF(t.product_category_name_english, ''), 'Unknown / Untranslated'),
       CAST(CAST(NULLIF(p.product_name_lenght, '') AS DECIMAL(12,2)) AS SIGNED),
       CAST(CAST(NULLIF(p.product_description_lenght, '') AS DECIMAL(12,2)) AS SIGNED),
       CAST(CAST(NULLIF(p.product_photos_qty, '') AS DECIMAL(12,2)) AS SIGNED),
       CAST(NULLIF(p.product_weight_g, '') AS DECIMAL(12,2)),
       CAST(NULLIF(p.product_length_cm, '') AS DECIMAL(12,2)),
       CAST(NULLIF(p.product_height_cm, '') AS DECIMAL(12,2)),
       CAST(NULLIF(p.product_width_cm, '') AS DECIMAL(12,2)),
       LOWER(p.dq_missing_attributes) = 'true',
       LOWER(p.dq_invalid_weight) = 'true'
FROM stg_products p
LEFT JOIN stg_category_translation t
  ON p.product_category_name = t.product_category_name;

/* Date dimension includes key 0 for missing optional dates.
   INSERT IGNORE makes this block safe to retry after a partial run.
   MySQL cannot reopen one temporary table multiple times within a single
   statement, so each source timestamp is inserted in its own statement. */
INSERT IGNORE INTO DimDate (date_key, full_date, `year`, `quarter`, `month`, month_name, `day`, day_of_week)
VALUES (0, '1900-01-01', 1900, 1, 1, 'Unknown', 1, 1);

INSERT IGNORE INTO DimDate (date_key, full_date, `year`, `quarter`, `month`, month_name, `day`, day_of_week)
SELECT DISTINCT YEAR(d)*10000+MONTH(d)*100+DAY(d), d, YEAR(d), QUARTER(d), MONTH(d), MONTHNAME(d), DAY(d), WEEKDAY(d)+1
FROM (SELECT DATE(STR_TO_DATE(NULLIF(order_purchase_timestamp,''), '%Y-%m-%d %H:%i:%s')) AS d FROM stg_orders) src
WHERE d IS NOT NULL AND d <> '1900-01-01';
INSERT IGNORE INTO DimDate (date_key, full_date, `year`, `quarter`, `month`, month_name, `day`, day_of_week)
SELECT DISTINCT YEAR(d)*10000+MONTH(d)*100+DAY(d), d, YEAR(d), QUARTER(d), MONTH(d), MONTHNAME(d), DAY(d), WEEKDAY(d)+1
FROM (SELECT DATE(STR_TO_DATE(NULLIF(order_approved_at,''), '%Y-%m-%d %H:%i:%s')) AS d FROM stg_orders) src
WHERE d IS NOT NULL AND d <> '1900-01-01';
INSERT IGNORE INTO DimDate (date_key, full_date, `year`, `quarter`, `month`, month_name, `day`, day_of_week)
SELECT DISTINCT YEAR(d)*10000+MONTH(d)*100+DAY(d), d, YEAR(d), QUARTER(d), MONTH(d), MONTHNAME(d), DAY(d), WEEKDAY(d)+1
FROM (SELECT DATE(STR_TO_DATE(NULLIF(order_delivered_carrier_date,''), '%Y-%m-%d %H:%i:%s')) AS d FROM stg_orders) src
WHERE d IS NOT NULL AND d <> '1900-01-01';
INSERT IGNORE INTO DimDate (date_key, full_date, `year`, `quarter`, `month`, month_name, `day`, day_of_week)
SELECT DISTINCT YEAR(d)*10000+MONTH(d)*100+DAY(d), d, YEAR(d), QUARTER(d), MONTH(d), MONTHNAME(d), DAY(d), WEEKDAY(d)+1
FROM (SELECT DATE(STR_TO_DATE(NULLIF(order_delivered_customer_date,''), '%Y-%m-%d %H:%i:%s')) AS d FROM stg_orders) src
WHERE d IS NOT NULL AND d <> '1900-01-01';
INSERT IGNORE INTO DimDate (date_key, full_date, `year`, `quarter`, `month`, month_name, `day`, day_of_week)
SELECT DISTINCT YEAR(d)*10000+MONTH(d)*100+DAY(d), d, YEAR(d), QUARTER(d), MONTH(d), MONTHNAME(d), DAY(d), WEEKDAY(d)+1
FROM (SELECT DATE(STR_TO_DATE(NULLIF(order_estimated_delivery_date,''), '%Y-%m-%d %H:%i:%s')) AS d FROM stg_orders) src
WHERE d IS NOT NULL AND d <> '1900-01-01';
INSERT IGNORE INTO DimDate (date_key, full_date, `year`, `quarter`, `month`, month_name, `day`, day_of_week)
SELECT DISTINCT YEAR(d)*10000+MONTH(d)*100+DAY(d), d, YEAR(d), QUARTER(d), MONTH(d), MONTHNAME(d), DAY(d), WEEKDAY(d)+1
FROM (SELECT DATE(STR_TO_DATE(NULLIF(shipping_limit_date,''), '%Y-%m-%d %H:%i:%s')) AS d FROM stg_order_items) src
WHERE d IS NOT NULL AND d <> '1900-01-01';
INSERT IGNORE INTO DimDate (date_key, full_date, `year`, `quarter`, `month`, month_name, `day`, day_of_week)
SELECT DISTINCT YEAR(d)*10000+MONTH(d)*100+DAY(d), d, YEAR(d), QUARTER(d), MONTH(d), MONTHNAME(d), DAY(d), WEEKDAY(d)+1
FROM (SELECT DATE(STR_TO_DATE(NULLIF(review_creation_date,''), '%Y-%m-%d %H:%i:%s')) AS d FROM stg_order_reviews) src
WHERE d IS NOT NULL AND d <> '1900-01-01';
INSERT IGNORE INTO DimDate (date_key, full_date, `year`, `quarter`, `month`, month_name, `day`, day_of_week)
SELECT DISTINCT YEAR(d)*10000+MONTH(d)*100+DAY(d), d, YEAR(d), QUARTER(d), MONTH(d), MONTHNAME(d), DAY(d), WEEKDAY(d)+1
FROM (SELECT DATE(STR_TO_DATE(NULLIF(review_answer_timestamp,''), '%Y-%m-%d %H:%i:%s')) AS d FROM stg_order_reviews) src
WHERE d IS NOT NULL AND d <> '1900-01-01';

INSERT INTO DimOrder (
 order_id, customer_id, order_status, order_purchase_timestamp, purchase_date_key,
 order_approved_at, approved_date_key, order_delivered_carrier_date, delivered_carrier_date_key,
 order_delivered_customer_date, delivered_customer_date_key, order_estimated_delivery_date,
 estimated_delivery_date_key, dq_missing_delivery_date, dq_canceled_but_delivered,
 reconciliation_status, difference, dq_financial_exception
)
SELECT o.order_id, o.customer_id, o.order_status,
       STR_TO_DATE(o.order_purchase_timestamp, '%Y-%m-%d %H:%i:%s'),
       COALESCE(DATE_FORMAT(STR_TO_DATE(o.order_purchase_timestamp, '%Y-%m-%d %H:%i:%s'), '%Y%m%d') + 0, 0),
       STR_TO_DATE(NULLIF(o.order_approved_at,''), '%Y-%m-%d %H:%i:%s'),
       COALESCE(DATE_FORMAT(STR_TO_DATE(NULLIF(o.order_approved_at,''), '%Y-%m-%d %H:%i:%s'), '%Y%m%d') + 0, 0),
       STR_TO_DATE(NULLIF(o.order_delivered_carrier_date,''), '%Y-%m-%d %H:%i:%s'),
       COALESCE(DATE_FORMAT(STR_TO_DATE(NULLIF(o.order_delivered_carrier_date,''), '%Y-%m-%d %H:%i:%s'), '%Y%m%d') + 0, 0),
       STR_TO_DATE(NULLIF(o.order_delivered_customer_date,''), '%Y-%m-%d %H:%i:%s'),
       COALESCE(DATE_FORMAT(STR_TO_DATE(NULLIF(o.order_delivered_customer_date,''), '%Y-%m-%d %H:%i:%s'), '%Y%m%d') + 0, 0),
       STR_TO_DATE(NULLIF(o.order_estimated_delivery_date,''), '%Y-%m-%d %H:%i:%s'),
       COALESCE(DATE_FORMAT(STR_TO_DATE(NULLIF(o.order_estimated_delivery_date,''), '%Y-%m-%d %H:%i:%s'), '%Y%m%d') + 0, 0),
       LOWER(o.dq_missing_delivery_date) = 'true',
       LOWER(o.dq_canceled_but_delivered) = 'true',
       NULLIF(o.reconciliation_status,''), CAST(NULLIF(o.difference,'') AS DECIMAL(12,2)),
       LOWER(o.dq_financial_exception) = 'true'
FROM stg_orders o;

INSERT INTO FactOrderItem (order_id, order_item_id, product_id, seller_id, shipping_limit_date, shipping_limit_date_key, price, freight_value)
SELECT i.order_id, CAST(i.order_item_id AS UNSIGNED), i.product_id, i.seller_id,
       STR_TO_DATE(NULLIF(i.shipping_limit_date,''), '%Y-%m-%d %H:%i:%s'),
       COALESCE(DATE_FORMAT(STR_TO_DATE(NULLIF(i.shipping_limit_date,''), '%Y-%m-%d %H:%i:%s'), '%Y%m%d') + 0, 0),
       CAST(i.price AS DECIMAL(12,2)), CAST(i.freight_value AS DECIMAL(12,2))
FROM stg_order_items i;

INSERT INTO FactPayment (order_id, payment_sequential, payment_type, payment_installments, payment_value)
SELECT order_id, CAST(payment_sequential AS UNSIGNED), payment_type,
       CAST(payment_installments AS UNSIGNED), CAST(payment_value AS DECIMAL(12,2))
FROM stg_order_payments;

INSERT INTO FactReview (
 review_id, order_id, review_score, review_creation_date, review_creation_date_key,
 review_answer_timestamp, review_answer_date_key, review_comment_title, review_comment_message
)
SELECT r.review_id, r.order_id, CAST(r.review_score AS UNSIGNED),
       STR_TO_DATE(NULLIF(r.review_creation_date,''), '%Y-%m-%d %H:%i:%s'),
       COALESCE(DATE_FORMAT(STR_TO_DATE(NULLIF(r.review_creation_date,''), '%Y-%m-%d %H:%i:%s'), '%Y%m%d') + 0, 0),
       STR_TO_DATE(NULLIF(r.review_answer_timestamp,''), '%Y-%m-%d %H:%i:%s'),
       COALESCE(DATE_FORMAT(STR_TO_DATE(NULLIF(r.review_answer_timestamp,''), '%Y-%m-%d %H:%i:%s'), '%Y%m%d') + 0, 0),
       NULLIF(r.review_comment_title,''), NULLIF(r.review_comment_message,'')
FROM stg_order_reviews r;

COMMIT;

/* ---------- 4. Final row-count check ---------- */
SELECT 'DimCustomer' AS table_name, COUNT(*) AS row_count FROM DimCustomer
UNION ALL SELECT 'DimSeller', COUNT(*) FROM DimSeller
UNION ALL SELECT 'DimProduct', COUNT(*) FROM DimProduct
UNION ALL SELECT 'DimOrder', COUNT(*) FROM DimOrder
UNION ALL SELECT 'DimDate', COUNT(*) FROM DimDate
UNION ALL SELECT 'FactOrderItem', COUNT(*) FROM FactOrderItem
UNION ALL SELECT 'FactPayment', COUNT(*) FROM FactPayment
UNION ALL SELECT 'FactReview', COUNT(*) FROM FactReview;


