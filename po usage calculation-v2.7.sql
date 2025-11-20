USE apothecary_po;

-- 0. change datatype of planned_shipment
alter table planned_shipment
	modify column quantity_unit DECIMAL(10,1),
	modify column unitpercase DECIMAL(10,1),
    modify column cases DECIMAL(10,1)
    ;
-- 0.1 add null to empty po_shipdate
UPDATE planned_shipment
SET po_shipdate = NULL
WHERE po_shipdate = '' OR po_shipdate NOT REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}$';


-- 1. create a pending_po sheet to filter all 'not started' POs

drop table if exists new_po;
create table new_po (
	status VARCHAR(255),
    po_shipdate date,
    sales_stream VARCHAR(255),
    distributor_stream VARCHAR(255),
    po_number VARCHAR(255),
    customerSKU VARCHAR(255),
    product_name VARCHAR(255),
    quantity_unit DECIMAL(10,1),
    CRA VARCHAR(255),
    unitpercase DECIMAL(10,1),
    cases DECIMAL(10,1),
    receiver VARCHAR(255)
);


insert into new_po (
	status,
    po_shipdate,
    sales_stream,
    distributor_stream,
    po_number,
    customerSKU,
    product_name,
    quantity_unit,
    CRA,
    unitpercase,
    cases,
    receiver
)
select 
	Status,
    po_shipdate,
    sales_stream,
    distributor_stream,
    po_number,
    customerSKU,
    product_name,
    quantity_unit,
    Excisedfor,
    unitpercase,
    cases,
    shipto

from planned_shipment
where status = 'not started';

-- 2. create new_po_summary group by productGTIN x caseGTIN

drop table if EXISTS new_po_summary;

create table new_po_summary (
	earliest_shipdate DATE,
    latest_shipdate DATE,
    productGTIN VARCHAR(255),
    caseGTIN TEXT,
    product_name VARCHAR(255),
    quantity_unit DECIMAL(10,1),
    case_size SMALLINT(4),
    cases DECIMAL(10,1)
);

insert into new_po_summary (
	earliest_shipdate,
    latest_shipdate,
    productGTIN,
    caseGTIN,
    product_name,
    quantity_unit,
    case_size,
    cases
)
select DISTINCT
	min(po_shipdate) AS earliest_shipdate,
    max(po_shipdate) AS latest_shipdate,
    concat(max(cs.productGTIN)) AS productGTIN,
    concat("'",max(cs.caseGTIN)) AS caseGTIN,
    max(np.product_name) AS product_name,
    sum(np.quantity_unit) AS quantity_unit,
    max(cs.case_size) AS case_size,
    sum(np.cases) AS cases
FROM 
	apothecary_po.new_po np
JOIN 
	customer_sku cs on np.customerSKU = cs.customerSKU
GROUP BY
	concat(np.product_name, cs.caseGTIN)
;




-- 3. create new_po_details

drop table if EXISTS new_po_details;

create table new_po_details (
	status VARCHAR(255),
    po_shipdate date,
    po_number VARCHAR(255),
    product_name VARCHAR(255),
    quantity_unit DECIMAL(10,1),
    CRA VARCHAR(255),
    unitpercase DECIMAL(10,1),
    cases DECIMAL(10,1),
    receiver VARCHAR(255)
);


insert into new_po_details (
	status,
    po_shipdate,
    po_number,
    product_name,
    quantity_unit,
    CRA,
    unitpercase,
    cases,
    receiver
)
select 
	Status,
    po_shipdate,
    po_number,
    product_name,
    quantity_unit,
    Excisedfor,
    unitpercase,
    cases,
    shipto

from 
	planned_shipment
where 
	status = 'not started'
order by
	concat(product_name, Excisedfor) DESC	
;


-- 4. Caculation of inventory of newPO new_po_sum_inventory

-- 4.0
drop table if exists production_plan_inventory_temporary;

create table production_plan_inventory_temporary(
	productGTIN VARCHAR(255),
    product_name VARCHAR(255),
    po_qty_unit DECIMAL (8,1),
    threshold_qty_unit DECIMAL (8,1),
    netweight_per_unit DECIMAL(5,1), 
    inventory_labelled_unit DECIMAL(8,1),
    inventory_packaged_unit DECIMAL(8,1),
    inventory_bulk_unit DECIMAL(8,1),
    inventory_bulk_netweight DECIMAL(8,1)
);

insert into production_plan_inventory_temporary (
	productGTIN,
    product_name,
    po_qty_unit
)
select
	nps.productGTIN,
    nps.product_name,
    nps.quantity_unit
from 
    new_po_summary nps
;
insert into production_plan_inventory_temporary (
	productGTIN,
    product_name,
    threshold_qty_unit
)
select
	pf.product_GTIN,
    pf.product_name,
    pf.qty
from 
	production_forecast pf
;

-- 4.0.1
drop table if exists production_plan_inventory;

create table production_plan_inventory(
	productGTIN VARCHAR(255),
    product_name VARCHAR(255),
    po_qty_unit DECIMAL (8,1),
    threshold_qty_unit DECIMAL (8,1),
    netweight_per_unit DECIMAL(5,1), 
    inventory_labelled_unit DECIMAL(8,1),
    inventory_packaged_unit DECIMAL(8,1),
    inventory_bulk_unit DECIMAL(8,1),
    inventory_bulk_netweight DECIMAL(8,1)
);    
insert into production_plan_inventory (
	productGTIN,
    product_name,
    po_qty_unit,
    threshold_qty_unit
)
select
	max(ppit.productGTIN) as productGTIN,
    max(ppit.product_name) as product_name,
    sum(ppit.po_qty_unit) as po_qty_unit,
    sum(ppit.threshold_qty_unit) as threshold_qty_unit
from 
production_plan_inventory_temporary ppit
group by
	concat(isnull(productGTIN),product_name)
;
drop table if exists production_plan_inventory_temporary
;

-- 4.1 update labelled inventory

update production_plan_inventory ppi   
join 
	productgtin_internalsku pi on ppi.productGTIN = pi.GTIN
join
	apothecary_inventory.caninventory_labelled_summary cls on pi.canSKU_labelled = cls.canSKU_labelled
set
	inventory_labelled_unit = cls.quantity_unit
;

-- 4.2 update packaged inventory 
update 
	production_plan_inventory  ppi
join 
	productgtin_internalsku pi on ppi.productGTIN = pi.GTIN
join
	apothecary_inventory.caninventory_packaged_summary cps on cps.canSKU_packaged = pi.canSKU_packaged 
set 
	inventory_packaged_unit = cps.quantity_unit;

-- 4.3 update bulk inventory
update 
	production_plan_inventory  ppi   
join 
	productgtin_internalsku pi on ppi.productGTIN = pi.GTIN
join
	apothecary_inventory.caninventory_bulk_summary cbs on cbs.canSKU_bulk = pi.canSKU_bulk 
set 
	inventory_bulk_unit = cbs.quantity_unit,
    inventory_bulk_netweight = cbs.net_weight;
    
	
    


-- 5. Calculation of cannabis inventory based on PO summary


/*
drop table if exists production_plan;

create table production_plan (
	earliest_shipdate DATE,
    latest_shipdate DATE,
    productGTIN VARCHAR(255),
    caseGTIN VARCHAR(255),
    product_name VARCHAR(255),
    order_quantity_unit DECIMAL(10,1),
    order_case_size SMALLINT(4),
    order_cases DECIMAL(10,1),
    labelled_needed_unit DECIMAL(10,1),
    packaged_needed_unit DECIMAL(10,1),
    bulk_needed_gram DECIMAL(10,1),
    bulk_needed_unit DECIMAL(10,1)
);

insert into production_plan(
	earliest_shipdate,
    latest_shipdate,
    productGTIN,
    caseGTIN,
    product_name,
    order_quantity_unit,
    order_case_size,
    order_cases,
	labelled_needed_unit,
    packaged_needed_unit,
    bulk_needed_gram,
    bulk_needed_unit
)
select 
	earliest_shipdate,
    latest_shipdate,
    productGTIN,
    caseGTIN,
    product_name,
    quantity_unit,
    case_size,
    cases
from
	new_po_summary nps
join 
*/
	