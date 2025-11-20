USE apothecary_ncinventory;

-- Step 0: change datatype of columns
ALTER TABLE noncannabis_log
	MODIFY COLUMN number_of_unit DECIMAL(10,1),
    MODIFY COLUMN quantity_gram_or_unit DECIMAL(10,2),
    MODIFY COLUMN time DATETIME,
    MODIFY COLUMN gross_weight DECIMAL(10,2);

ALTER TABLE ncdailychange
	MODIFY COLUMN quantity_change_unit DECIMAL(10,1),
    MODIFY COLUMN quantity_change_net_weight DECIMAL(10,2),
    MODIFY COLUMN time DATETIME,
    MODIFY COLUMN quantity_change_gross_weight DECIMAL(10,2);

-- Step 1: Create the change_sums table

drop table if exists ncchange_sums;

CREATE TABLE ncchange_sums (
    ncinventory_id VARCHAR(225),
    unit_change DECIMAL(10, 2),
    gross_weight_change DECIMAL(10, 2),
    net_weight_sum DECIMAL(10, 2),
    start_time DATETIME,
    real_time DATETIME,
    stage_change VARCHAR(255)
);


-- Step 2: Insert calculated values into change_sums
INSERT INTO ncchange_sums (
    ncinventory_id, 
    unit_change, 
    gross_weight_change, 
    net_weight_sum, 
    start_time, 
    real_time, 
    stage_change
)

SELECT 
    ndc.ncinventory_id,

    -- Column 1: Sum of ndc.quantity_change_unit
    SUM(ndc.quantity_change_unit) AS unit_change,

    -- Column 2: Sum of ndc.quantity_change_gross_weight
    SUM(ndc.quantity_change_gross_weight) AS gross_weight_change,

    -- Column 3: Sum of ndc.quantity_change_net_weight
    SUM(ndc.quantity_change_net_weight) AS net_weight_sum,

    -- Column 4: start_time (use MIN() or MAX() as per logic)
    MIN(ncl.time) AS start_time,

    -- Column 5: real_time (latest time between ncl.time and ndc.time)
	GREATEST(MIN(ncl.time), MAX(ndc.time)) AS real_time,

    -- Column 6: status_change; Copy stage_change to the change_sums sheet, decide which to use when combining change_sums sheet and ncl sheet 
    MAX(ndc.stage_change) AS stage_change	

FROM 
    ncdailychange ndc 
LEFT JOIN 
    noncannabis_log ncl
    ON ncl.nc_inventory_id = ndc.ncinventory_id AND ndc.time > ncl.time
WHERE
	ncl.time < ndc.time
GROUP BY 
    ndc.ncinventory_id;

-- Step 2.1 Drop the rolls that contains null start time and end time, recall line 51 that only ndc.time > ncl.time were included in the above statement
DELETE FROM ncchange_sums
WHERE start_time IS NULL
   OR real_time IS NULL;



-- Step 3 Combine change_sums with noncannabis_log to get the real-time cannabis inventory

drop table if exists noncaninventory_rt;

CREATE TABLE noncaninventory_rt AS
SELECT *
FROM noncannabis_log;

-- 3.1 delete inactive articles
DELETE FROM noncaninventory_rt ncr
WHERE ncr.status='Closed';
 
 -- 3.2 create and modify columns to add the reat time data
ALTER TABLE noncaninventory_rt
	ADD COLUMN unit_rt DECIMAL(10, 1),
	ADD COLUMN gross_weight_rt DECIMAL(10, 2),
	ADD COLUMN net_weight_rt DECIMAL(10, 2),
	ADD COLUMN real_time DATETIME,
	ADD COLUMN stage_rt VARCHAR(255);

ALTER TABLE noncaninventory_rt
	MODIFY COLUMN	quantity_gram_or_unit DECIMAL(10, 2),
	MODIFY COLUMN	gross_weight DECIMAL(10, 2),
	MODIFY COLUMN	number_of_unit DECIMAL(10, 1);

-- 3.3 add cs and ncl data
UPDATE noncaninventory_rt ncr
LEFT JOIN ncchange_sums ncs ON ncr.nc_inventory_id = ncs.ncinventory_id
SET
    ncr.unit_rt = ncr.number_of_unit + COALESCE(ncs.unit_change, 0),
    ncr.gross_weight_rt = ncr.gross_weight + COALESCE(ncs.gross_weight_change, 0),
    ncr.net_weight_rt = CASE
		WHEN ncr.calculation_method = 'net' THEN	ncr.quantity_gram_or_unit + COALESCE(ncs.net_weight_sum, 0)
		ELSE ncr.quantity_gram_or_unit + coalesce(ncs.gross_weight_change, 0)
        END,
        
	ncr.real_time = CASE
		WHEN ncs.real_time IS NULL THEN ncr.time
        ELSE GREATEST(ncr.time, ncs.real_time)
        END,
        
    ncr.stage_rt = ncr.stage;
    
-- 3.4 add status column to each article: in-vault, out-vault, error
ALTER TABLE noncaninventory_rt
	ADD COLUMN status_rt VARCHAR(255);

UPDATE noncaninventory_rt ncr
SET	ncr.status_rt = CASE
	WHEN ncr.net_weight_rt > 0 AND ncr.status= 'Active' THEN 'in-vault'
    WHEN ncr.net_weight_rt <= 0 AND ncr.gross_weight_rt = 0 AND ncr.status= 'Active' THEN 'outside-vault'
    WHEN ncr.status= 'OutsideLP' AND ncr.net_weight_rt >0 THEN 'outside-LP'
    ELSE 'error'
END;


    
-- 3.4 Delete unuseful columns

ALTER TABLE noncaninventory_rt 
	DROP COLUMN	status,
	DROP COLUMN time,
	DROP COLUMN gross_weight,
	DROP COLUMN calculation_method;

-- 3.5 Rearrange columns 

drop table if exists noncannabis_inventory_data;

CREATE TABLE noncannabis_inventory_data(
	ncinventory_id VARCHAR(225),
    product_status VARCHAR(225),
	location VARCHAR(225),
    stage VARCHAR(225),
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
    
INSERT INTO noncannabis_inventory_data(
	ncinventory_id,
    product_status,
	location,
    stage,
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
    nc_inventory_id,
    status_rt,
    location,
    stage_rt,
    product_description,
    lot_number,
    pack_on_date,
    unit_rt,
    unit,
    gross_weight_rt,
    net_weight_rt,
    real_time,
    note
    FROM noncaninventory_rt;

-- 4.0 create noncannabis_summary

DROP TABLE IF EXISTS noncannabis_summary;

CREATE TABLE noncannabis_summary (
	ncSKU TINYTEXT,
    location VARCHAR(225),
    stage TINYTEXT,
	category TINYTEXT,
	product_description VARCHAR(225),
	number_of_unit DECIMAL(10, 1),
    unit VARCHAR(225),
	avg_netqty_per_unit DECIMAL(10,2),
    quantity_gram_or_unit DECIMAL(10,2)
);

INSERT INTO noncannabis_summary(
	ncSKU,
    location, 
	stage,
    category,
	product_description,
	number_of_unit,
    unit,
	avg_netqty_per_unit,
    quantity_gram_or_unit
    )
SELECT  DISTINCT
	ncSKU,
    max(location), 
	max(stage),
    max(category),
	max(product_description),
	sum(unit_rt),
    max(unit),
	avg(net_qty_per_unit),
    sum(quantity_gram_or_unit)
FROM 
	apothecary_ncinventory.noncaninventory_rt
group by
	ncSKU
order by 
	max(category)
;
	