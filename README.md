# SQL-EXCEL-based-cannabis-data-system-

## Background
- This data tracking system was designed to help any manufacturing company who cannot afford a proper ERP software. However, the accurate tracebility of massive product, inventory and shipment data flow is required for all purposes of operational and compliant needs.   

- This system is in compliance with Cannabis Act, Cannabis Regulation, Good Production Practices(GPP), and Health Canada 

## Constitution 

### Excel-based data collections
- template has been provided to retain all fomulation, partial data is retained to serve as examples.

### SQL-based inventory control
- inlcudes 2 data files: cannabislog and dailychange. Cannabis log focuses on tracking product information (e.g. location, type, pack-on-date, name, qty, inventory_id, SKU_id ); dailychange records all the inbound/outbound (qty changes) of a specific inventory entity(invnetory_id).
  
- traces both discrete (e.g. a unit of preroll) and indiscrete (e.g. bagged bulk flower) units . The countability of the former is based on the unit count, and the latter is through tracking net (net = gross-tare) weight change.
  
- generates 7 data files: 4 classes of material information in detail and summary: bulk type (raw material), packaged type (in-proccess material), labelled type (shipment-ready products) and inventory data (details of all inventory_id)

### SQL-based non-cannabis inventory

### SQL-based inventory usage calculation 
