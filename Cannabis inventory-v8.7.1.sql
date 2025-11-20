-- Version 8.7.1 note
-- acconmodate the change of caninv_id xx-x

USE apothecary_inventory;

-- Step 0: change datatype of columns
ALTER TABLE cannabis_log
	MODIFY COLUMN inventory_id TEXT,
    MODIFY COLUMN number_of_unit DECIMAL(10,1),
    MODIFY COLUMN quantity_gram DECIMAL(10,2),
    MODIFY COLUMN time DATETIME,
    MODIFY COLUMN gross_weight DECIMAL(10,2);

ALTER TABLE dailychange
	MODIFY COLUMN quantity_change_unit DECIMAL(10,1),
    MODIFY COLUMN quantity_change_net_weight DECIMAL(10,2),
    MODIFY COLUMN time DATETIME,
    MODIFY COLUMN quantity_change_gross_weight DECIMAL(10,2);

-- Step 1: Create the change_sums table

drop table if exists change_sums;

CREATE TABLE change_sums (
    inventory_id TEXT,
    unit_change DECIMAL(10, 2),
    gross_weight_change DECIMAL(10, 2),
    net_weight_sum DECIMAL(10, 2),
    start_time DATETIME,
    real_time DATETIME
);


-- Step 2: Insert calculated values into change_sums
INSERT INTO change_sums (
    inventory_id, 
    unit_change, 
    gross_weight_change, 
    net_weight_sum, 
    start_time, 
    real_time
)

SELECT 
    dc.inventory_id,

    -- Column 1: Sum of dc.quantity_change_unit
    SUM(dc.quantity_change_unit) AS unit_change,

    -- Column 2: Sum of dc.quantity_change_gross_weight
    SUM(dc.quantity_change_gross_weight) AS gross_weight_change,

    -- Column 3: Sum of dc.quantity_change_net_weight
    SUM(dc.quantity_change_net_weight) AS net_weight_sum,

    -- Column 4: start_time (use MIN() or MAX() as per logic)
    MIN(cl.time) AS start_time,

    -- Column 5: real_time (latest time between cl.time and dc.time)
	GREATEST(MIN(cl.time), MAX(dc.time)) AS real_time

/*
    -- Column 6: status_change; Copy stage_change to the change_sums sheet, decide which to use when combining change_sums sheet and cl sheet 
    MAX(dc.stage_change) AS stage_change	
*/
FROM 
    dailychange dc 
LEFT JOIN 
    cannabis_log cl
    ON cl.inventory_id = dc.inventory_id AND dc.time > cl.time
WHERE
	cl.time < dc.time
GROUP BY 
    dc.inventory_id;

-- Step 2.1 Drop the rolls that contains null start time and end time, recall line 51 that only dc.time > cl.time were included in the above statement
DELETE FROM change_sums
WHERE start_time IS NULL
   OR real_time IS NULL;
   



-- Step 3 Combine change_sums with cannabis_log to get the real-time cannabis inventory

drop table if exists caninventory_rt;

CREATE TABLE caninventory_rt AS
SELECT *
FROM cannabis_log;

-- 3.1 delete inactive articles
DELETE FROM caninventory_rt cr
WHERE cr.status='Closed';

 
 -- 3.2 create and modify columns to add the reat time data
ALTER TABLE caninventory_rt
	ADD COLUMN unit_rt DECIMAL(10, 1),
	ADD COLUMN gross_weight_rt DECIMAL(10, 2),
	ADD COLUMN net_weight_rt DECIMAL(10, 2),
	ADD COLUMN real_time DATETIME,
	ADD COLUMN stage_rt VARCHAR(255);

ALTER TABLE caninventory_rt
	MODIFY COLUMN	quantity_gram DECIMAL(10, 2),
	MODIFY COLUMN	gross_weight DECIMAL(10, 2),
	MODIFY COLUMN	number_of_unit DECIMAL(10, 1);

-- 3.3 add cs and cl data
UPDATE caninventory_rt cr
LEFT JOIN change_sums cs ON cr.inventory_id = cs.inventory_id
SET
    cr.unit_rt = cr.number_of_unit + COALESCE(cs.unit_change, 0),
    cr.gross_weight_rt = cr.gross_weight + COALESCE(cs.gross_weight_change, 0),
    cr.net_weight_rt = CASE
		WHEN cr.calculation_method = 'net' THEN	cr.quantity_gram + COALESCE(cs.net_weight_sum, 0)
		WHEN cr.calculation_method = 'gross' AND cr.quantity_gram + coalesce(cs.gross_weight_change, 0) + tare_weight = 0 THEN 0
        WHEN cr.calculation_method = 'gross'  AND cr.quantity_gram + coalesce(cs.gross_weight_change, 0) >= 0 THEN cr.quantity_gram + coalesce(cs.gross_weight_change, 0) -- gross method calculation formula = starting value + gross wt change	
        ELSE null
        END,
        
	cr.real_time = CASE
		WHEN cs.real_time IS NULL THEN cr.time
        ELSE GREATEST(cr.time, cs.real_time)
        END,
    cr.stage_rt = cr.stage
   ;
    
-- 3.4 add status column to each article: in-vault, out-vault, error
ALTER TABLE caninventory_rt
	ADD COLUMN status_rt VARCHAR(255);
    

UPDATE caninventory_rt cr
SET	cr.status_rt = CASE
	WHEN cr.unit_rt >= 0 AND cr.net_weight_rt > 0 AND cr.status= 'Active' THEN 'in-vault'
    WHEN cr.unit_rt = 0 AND cr.net_weight_rt = 0 AND cr.calculation_method = 'net' AND cr.status= 'Active' THEN 'outside-vault'
    WHEN cr.unit_rt = 0 AND cr.gross_weight_rt = 0 AND cr.calculation_method = 'gross' AND cr.status= 'Active' THEN 'outside-vault'
    WHEN cr.status= 'OutsideLP' AND cr.calculation_method = 'net' AND cr.net_weight_rt >0 THEN 'outside-LP available'
    WHEN cr.status= 'OutsideLP' AND cr.calculation_method = 'net' AND cr.net_weight_rt =0 THEN 'outside-LP depleted'
    WHEN cr.status= 'OutsideLP' AND cr.calculation_method = 'net' AND cr.net_weight_rt <0 THEN 'outside-LP error'
    ELSE 'error_unit/weight'

END
;


UPDATE caninventory_rt cr
SET cr.status_rt = CASE
	WHEN  DATEDIFF(CURDATE(), pack_on_date) < 0 THEN 'error_POD' 
    ELSE 'in-vault'
END
WHERE pack_on_date IS NOT NULL
    AND pack_on_date != 'NA'
    AND pack_on_date != ''
    AND (
        (pack_on_date LIKE '%/%/%' AND STR_TO_DATE(pack_on_date, '%Y/%m/%d') IS NOT NULL) OR
        (pack_on_date LIKE '%-%-%' AND STR_TO_DATE(pack_on_date, '%Y-%m-%d') IS NOT NULL)
    )
    AND cr.status_rt ='in-vault';

    
-- 3.4 Delete unuseful columns

ALTER TABLE caninventory_rt 
	DROP COLUMN bag_number,
	DROP COLUMN tote_number,
	DROP COLUMN stage,
	DROP COLUMN time,
	DROP COLUMN number_of_unit,
	DROP COLUMN gross_weight,
	DROP COLUMN quantity_gram;
    
-- 3.4.1 Delete at least 1-month inactive net/gross weight=0 rows

DELETE FROM caninventory_rt 
	WHERE status = 'Active' AND status_rt = 'outside-vault' AND unit_rt = 0 AND DATEDIFF(CURDATE(),real_time)>31;

-- 3.5 Create inventory data 

drop table if exists inventory_data;

CREATE TABLE inventory_data(
	inventory_id TEXT,
    product_status VARCHAR(225),
	location VARCHAR(225),
    stage VARCHAR(225),
    internal_cansku smallint (4),
	product_description VARCHAR(225),
	lot_number TINYTEXT,
	pack_on_date TEXT,
	quantity_unit DECIMAL(10, 1),
    unit_name VARCHAR(225),
	gross_weight DECIMAL(10,2),
	net_weight DECIMAL(10,2),
    check_time DATETIME,
    note VARCHAR(225)
    );
    
INSERT INTO inventory_data(
	inventory_id,
    product_status,
	location,
    stage,
    internal_cansku,
	product_description,
	lot_number,
	pack_on_date,
	quantity_unit,
    unit_name,
	gross_weight,
	net_weight,
    check_time,
    note
    )
	SELECT
    inventory_id,
    status_rt,
    location,
    stage_rt,
    internal_cansku,
    product_description,
    lot_number,
    pack_on_date,
    unit_rt,
    unit,
    gross_weight_rt,
    net_weight_rt,
    real_time,
    note
    FROM caninventory_rt;
    
-- 4.0 CREATE caninventory_labelled_details

DROP TABLE IF EXISTS caninventory_labelled_details;

CREATE TABLE caninventory_labelled_details (
    inventory_id TEXT,
    location VARCHAR(225),
    productGTIN VARCHAR(255),
    product_status VARCHAR(225),
    stage VARCHAR(225),
	product_description VARCHAR(225),
	lot_number TINYTEXT,
	pack_on_date TEXT,
    days_since_produced INT,
	quantity_unit DECIMAL(10, 1),
    unit_name VARCHAR(225),
	net_weight DECIMAL(10,2),
    check_time DATETIME,
    note VARCHAR(225)
);

INSERT INTO caninventory_labelled_details(
    inventory_id,
    location,
    productGTIN,
    product_status,  
	stage,
	product_description,
	lot_number,
	pack_on_date,
	quantity_unit,
    unit_name,
	net_weight,
    check_time,
    note
    )
SELECT
    inventory_id,
    location,
    GTIN,
    status_rt,
    stage_rt,
    product_description,
    lot_number,
    pack_on_date,
    unit_rt,
    unit,
    net_weight_rt,
    real_time,
    note
FROM 
	apothecary_inventory.caninventory_rt cr
join 
	apothecary_po.productgtin_internalsku pi on cr.internal_cansku = pi.canSKU_labelled
order by
	internal_cansku
;
	

-- 4.1 ADD days_since_produced to caninventory_labelled_details

UPDATE caninventory_labelled_details
SET days_since_produced = DATEDIFF(CURDATE(), 
    CASE
        WHEN pack_on_date LIKE '%/%/%' THEN STR_TO_DATE(pack_on_date, '%Y/%m/%d')
        WHEN pack_on_date LIKE '%-%-%' THEN STR_TO_DATE(pack_on_date, '%Y-%m-%d')
        ELSE NULL
    END
)
WHERE pack_on_date IS NOT NULL
    AND pack_on_date != 'NA'
    AND pack_on_date != ''
    AND (
        (pack_on_date LIKE '%/%/%' AND STR_TO_DATE(pack_on_date, '%Y/%m/%d') IS NOT NULL) OR
        (pack_on_date LIKE '%-%-%' AND STR_TO_DATE(pack_on_date, '%Y-%m-%d') IS NOT NULL)
    );



  
-- 4.2 CREATE caninventory_labelled_summary

DROP TABLE IF EXISTS caninventory_labelled_summary;

CREATE TABLE caninventory_labelled_summary (
    canSKU_labelled int,
	product_description VARCHAR(225),
	quantity_unit DECIMAL(10, 1),
    unit_name TEXT,
	net_weight DECIMAL(10,2)
);

INSERT INTO caninventory_labelled_summary(
    canSKU_labelled,
	product_description,
	quantity_unit,
    unit_name,
	net_weight
    )
SELECT
    canSKU_labelled,
    max(product_description) as product_description,
    sum(unit_rt) as quantity_unit,
    max(unit) as unit_name,
    sum(net_weight_rt) as net_weight
FROM 
	apothecary_inventory.caninventory_rt cr
join 
	apothecary_po.productgtin_internalsku pi on cr.internal_cansku = pi.canSKU_labelled
where
	cr.status_rt = "in-vault"
group by 
	cr.internal_cansku
order by
	cr.internal_cansku
;

-- 5.1 CREATE caninventory_packaged_details

DROP TABLE IF EXISTS caninventory_packaged_details;

CREATE TABLE caninventory_packaged_details (
    inventory_id TEXT,
    location VARCHAR(225),
    productGTIN VARCHAR(255),
    product_status VARCHAR(225),
    stage VARCHAR(225),
	product_description VARCHAR(225),
	lot_number TINYTEXT,
	pack_on_date TEXT,
    days_since_produced INT,
	quantity_unit DECIMAL(10, 1),
    unit_name VARCHAR(225),
	net_weight DECIMAL(10,2),
    check_time DATETIME,
    note VARCHAR(225)
);

INSERT INTO caninventory_packaged_details(
    inventory_id,
    location,
    productGTIN,
    product_status,  
	stage,
	product_description,
	lot_number,
	pack_on_date,
	quantity_unit,
    unit_name,
	net_weight,
    check_time,
    note
    )
SELECT
    inventory_id,
    location,
    GTIN,
    status_rt,
    stage_rt,
    product_description,
    lot_number,
    pack_on_date,
    unit_rt,
    unit,
    net_weight_rt,
    real_time,
    note
FROM 
	apothecary_inventory.caninventory_rt cr
join 
	apothecary_po.productgtin_internalsku pi on cr.internal_cansku = pi.canSKU_packaged
order by
	internal_cansku
;

-- 5.2 CREATE caninventory_packaged_summary

DROP TABLE IF EXISTS caninventory_packaged_summary;

CREATE TABLE caninventory_packaged_summary (
    canSKU_packaged smallint(4),
	product_description VARCHAR(225),
	quantity_unit DECIMAL(10, 1),
    unit_name TEXT,
	net_weight DECIMAL(10,2)
);

INSERT INTO caninventory_packaged_summary(
    canSKU_packaged,
	product_description,
	quantity_unit,
    unit_name,
	net_weight
    )
SELECT
    canSKU_packaged,
    max(product_description) as product_description,
    sum(unit_rt) as quantity_unit,
    max(unit) as unit_name,
    sum(net_weight_rt) as net_weight
FROM 
	apothecary_inventory.caninventory_rt cr
join 
	apothecary_po.productgtin_internalsku pi on cr.internal_cansku = pi.canSKU_packaged
where
	cr.status_rt = "in-vault"
group by 
	cr.internal_cansku
order by
	cr.internal_cansku
;
	
-- 5.3 CREATE caninventory_bulk_details

DROP TABLE IF EXISTS caninventory_bulk_details;

CREATE TABLE caninventory_bulk_details (
    inventory_id TEXT,
    location VARCHAR(255),
    productGTIN VARCHAR(255),
    product_status VARCHAR(225),
    canSKU_bulk TEXT,
    stage VARCHAR(225),
	product_description VARCHAR(225),
	lot_number TINYTEXT,
	pack_on_date TEXT,
    days_since_produced INT,
	quantity_unit DECIMAL(10, 1),
    unit_name VARCHAR(225),
	net_weight DECIMAL(10,2),
    check_time DATETIME,
    note VARCHAR(225)
);

INSERT INTO caninventory_bulk_details(
    inventory_id,
    location,
    productGTIN,
    product_status,
    canSKU_bulk,
	stage,
	product_description,
	lot_number,
	pack_on_date,
	quantity_unit,
    unit_name,
	net_weight,
    check_time,
    note
    )
SELECT
    inventory_id,
    location,
    GTIN,
    status_rt,
    internal_cansku,
    stage_rt,
    product_description,
    lot_number,
    pack_on_date,
    unit_rt,
    unit,
    net_weight_rt,
    real_time,
    note
FROM 
	apothecary_inventory.caninventory_rt cr
join 
	apothecary_po.productgtin_internalsku pi on cr.internal_cansku = pi.canSKU_bulk
order by
	internal_cansku
;

-- 5.4 create caninventory_bulk_summary

drop table if exists caninventory_bulk_summary;

CREATE TABLE caninventory_bulk_summary (
    canSKU_bulk TEXT,
	product_description VARCHAR(225),
    stage VARCHAR(225),
	quantity_unit DECIMAL(10, 1),
    unit_name VARCHAR(225),
	net_weight DECIMAL(10,2)
);

INSERT INTO caninventory_bulk_summary(
	canSKU_bulk,
	product_description,
    stage,
	quantity_unit,
    unit_name,
	net_weight
    )
SELECT
    canSKU_bulk,
    max(product_description),
    max(stage),
    sum(quantity_unit),
    max(unit_name),
    sum(net_weight)
FROM 
	caninventory_bulk_details
group by
	canSKU_bulk
;


-- 6. data cleaning
-- 6.1 summarize all error rows

drop table if exists caninventory_errors;

CREATE TABLE caninventory_errors (
    inventory_id TEXT,
    product_status VARCHAR(225),
    location VARCHAR(225),
    stage VARCHAR(225),
	product_description VARCHAR(225),
    lot_number VARCHAR(225),
    pack_on_date TEXT,
	quantity_unit DECIMAL(10, 1),
    unit_name VARCHAR(225),
	net_weight DECIMAL(10,2),
    check_time datetime
);

INSERT INTO caninventory_errors(
    inventory_id,
    product_status,
    location,
    stage,
	product_description,
    lot_number,
    pack_on_date,
	quantity_unit,
    unit_name,
	net_weight,
    check_time
    )
SELECT
	inventory_id,
    status_rt,
    location,
    stage_rt,
    product_description,
    lot_number,
    pack_on_date,
    unit_rt,
    unit,
    net_weight_rt,
    real_time
FROM 
	caninventory_rt
WHERE	
	status_rt like 'error_%';

	