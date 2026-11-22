# international-logistics-sql-analysis
# International Logistics & Last-Mile Delivery Bottleneck Analysis (SQL)

## Project Overview & Business Context
Cross-border e-commerce logistics relies heavily on predictable transit times and transparent carrier performance. Inspired by real-world international parcel operations (SCOR framework), this project simulates an end-to-end logistics pipeline to identify operational bottlenecks, quantify customs clearance tail delays, and link SLA compliance with financial metrics (**Unit Cost per kg** and **Days Sales Outstanding**).

## Repository Structure
* **`01_schema_and_seed_data.sql`** — Creates a normalized 3-table PostgreSQL schema (`carriers`, `shipments`, `tracking_events`) and generates 500 synthetic international parcel shipments with realistic operational anomalies (customs bottlenecks, duplicate barcode scans, and overdue B2B invoices).
* **`02_analytical_queries.sql`** — Contains data-cleaning pipelines, stage-by-stage dwell time calculations, p95 outlier benchmarks, financial KPI aggregations, and a production-ready SQL view for BI tools.

## Database Architecture
* **`carriers`**: Carrier directory with regional coverage, target transit SLAs (in hours), and base rates.
* **`shipments`**: Order-level metadata including origin/destination routes, assigned customs hub, parcel weight, freight costs, and B2B billing dates.
* **`tracking_events`**: Event-level timestamp logs (`Order_Created` → `Picked_Up` → `Customs_In` → `Customs_Cleared` → `Last_Mile_Hub` → `Delivered`).

## Key SQL Techniques Demonstrated
* **Data Cleaning & Deduplication**: Eliminated duplicate scanner status events using `ROW_NUMBER() OVER (PARTITION BY ...)` and `DISTINCT ON`, and handled open/unpaid invoices via `COALESCE`.
* **Stage-by-Stage Dwell Time Analysis**: Leveraged Common Table Expressions (CTEs) and window functions (`LAG()`) to calculate exact hours spent between consecutive tracking checkpoints.
* **Outlier & SLA Benchmarking**: Used `PERCENTILE_CONT(0.95)` to measure **95th percentile (p95)** customs clearance times rather than relying solely on skewed averages.
* **BI Reporting Layer**: Built a denormalized analytical view (`vw_logistics_kpi_summary`) ready for direct connection to **Power BI**.

## Key Analytical Findings
1. **Customs Bottleneck Identification**: `Jagodzin-Dorohusk Hub` drives the majority of SLA breaches, showing a **p95 customs clearance time of ~76 hours** compared to ~17 hours at other checkpoints.
2. **Financial & Cash-Flow Impact**: Routes experiencing prolonged customs delays correlate with lower On-Time Delivery (OTD %) rates and extended B2B invoice collection cycles (higher **DSO**).

## 🚀 How to Run
1. Run `01_schema_and_seed_data.sql` in **PostgreSQL 14+** (or [DB Fiddle](https://www.db-fiddle.com/) with PostgreSQL selected) to create the tables and populate the dataset.
2. Run `02_analytical_queries.sql` to execute the analytical queries and generate the `vw_logistics_kpi_summary` reporting view.
