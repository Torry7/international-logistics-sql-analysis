/* ============================================================================
   PROJECT: International Logistics & Last-Mile Delivery Bottleneck Analysis
   FILE: 01_schema_and_seed_data.sql
   AUTHOR: Viktoriia Sobolta
   DIALECT: PostgreSQL 14+
   DESCRIPTION:
   Step 1 of the analytical pipeline. Creates a normalized relational schema
   (carriers, shipments, tracking_events) and populates it with 500 synthetic
   cross-border parcel shipments along with realistic operational anomalies:
     - Heavy customs clearance delays at Jagodzin-Dorohusk Hub (36-78h)
     - Duplicate scanner tracking logs (every 7th shipment at Customs_In)
     - B2B invoice payment delays and open receivables for DSO modeling
   ============================================================================ */

-- ----------------------------------------------------------------------------
-- 1. CLEANUP EXISTING OBJECTS (Idempotent Setup)
-- ----------------------------------------------------------------------------
DROP VIEW IF EXISTS vw_logistics_kpi_summary;
DROP TABLE IF EXISTS tracking_events;
DROP TABLE IF EXISTS shipments;
DROP TABLE IF EXISTS carriers;

-- ----------------------------------------------------------------------------
-- 2. TABLE DEFINITIONS (DDL)
-- ----------------------------------------------------------------------------

-- Carrier directory with regional coverage, target SLA, and base rates
CREATE TABLE carriers (
    carrier_id SERIAL PRIMARY KEY,
    carrier_name VARCHAR(100) NOT NULL,
    region VARCHAR(50) NOT NULL,
    sla_transit_hours INT NOT NULL,
    base_rate_eur NUMERIC(10, 2) NOT NULL
);

-- Shipment-level order, routing, freight cost, and billing metadata
CREATE TABLE shipments (
    shipment_id INT PRIMARY KEY,
    tracking_number VARCHAR(30) UNIQUE NOT NULL,
    carrier_id INT REFERENCES carriers(carrier_id),
    origin_country VARCHAR(50) NOT NULL,
    destination_country VARCHAR(50) NOT NULL,
    customs_hub VARCHAR(50) NOT NULL,
    weight_kg NUMERIC(6, 2) NOT NULL,
    freight_cost_eur NUMERIC(10, 2) NOT NULL,
    invoice_amount_eur NUMERIC(10, 2) NOT NULL,
    created_at TIMESTAMP NOT NULL,
    promised_delivery_at TIMESTAMP NOT NULL,
    invoice_issued_at DATE NOT NULL,
    invoice_paid_at DATE -- NULL indicates unpaid / open B2B receivable
);

-- Event-level tracking logs across sorting centers, customs, and last mile
CREATE TABLE tracking_events (
    event_id SERIAL PRIMARY KEY,
    shipment_id INT REFERENCES shipments(shipment_id),
    status VARCHAR(50) NOT NULL,
    event_timestamp TIMESTAMP NOT NULL,
    hub_location VARCHAR(100)
);

-- ----------------------------------------------------------------------------
-- 3. SEED DATA GENERATION (DML)
-- ----------------------------------------------------------------------------

-- Populate carrier reference table
INSERT INTO carriers (carrier_name, region, sla_transit_hours, base_rate_eur) VALUES
('BalticExpress Line', 'Baltics', 72, 12.50),
('EuroPost Connect', 'Central Europe', 96, 10.80),
('IberiaParcel LastMile', 'Southern Europe', 144, 15.20),
('Vistula Freight & Customs', 'CEE', 84, 11.40);

-- Generate 500 international shipments across Q3-Q4 2026
INSERT INTO shipments (
    shipment_id, tracking_number, carrier_id, origin_country, destination_country,
    customs_hub, weight_kg, freight_cost_eur, invoice_amount_eur,
    created_at, promised_delivery_at, invoice_issued_at, invoice_paid_at
)
SELECT 
    gs AS shipment_id,
    'TRK2026' || LPAD(gs::TEXT, 6, '0') AS tracking_number,
    (gs % 4) + 1 AS carrier_id,
    'Ukraine' AS origin_country,
    CASE (gs % 4)
        WHEN 0 THEN 'Lithuania'
        WHEN 1 THEN 'Poland'
        WHEN 2 THEN 'Spain'
        ELSE 'Germany'
    END AS destination_country,
    CASE (gs % 3)
        WHEN 0 THEN 'Medyka-Shehyni Hub'
        WHEN 1 THEN 'Jagodzin-Dorohusk Hub'
        ELSE 'Kyiv Air Cargo Terminal'
    END AS customs_hub,
    ROUND((1.5 + (gs % 18) * 0.85)::NUMERIC, 2) AS weight_kg,
    ROUND((14.00 + (gs % 18) * 2.10)::NUMERIC, 2) AS freight_cost_eur,
    ROUND((22.00 + (gs % 18) * 3.40)::NUMERIC, 2) AS invoice_amount_eur,
    TIMESTAMP '2026-08-01 08:00:00' + (gs * INTERVAL '4 hours') AS created_at,
    TIMESTAMP '2026-08-01 08:00:00' + (gs * INTERVAL '4 hours') + INTERVAL '5 days' AS promised_delivery_at,
    (TIMESTAMP '2026-08-01 08:00:00' + (gs * INTERVAL '4 hours') + INTERVAL '1 day')::DATE AS invoice_issued_at,
    -- Simulate DSO delays for every 5th B2B invoice; 5% remain open/unpaid
    CASE 
        WHEN gs % 20 = 0 THEN NULL
        WHEN gs % 5 = 0 THEN (TIMESTAMP '2026-08-01 08:00:00' + (gs * INTERVAL '4 hours') + INTERVAL '42 days')::DATE
        ELSE (TIMESTAMP '2026-08-01 08:00:00' + (gs * INTERVAL '4 hours') + INTERVAL '14 days')::DATE
    END AS invoice_paid_at
FROM generate_series(1, 500) AS gs;

-- Generate sequential tracking events with an injected bottleneck at Jagodzin-Dorohusk Hub
INSERT INTO tracking_events (shipment_id, status, event_timestamp, hub_location)
SELECT shipment_id, 'Order_Created', created_at, 'Lviv Sorting Center' FROM shipments
UNION ALL
SELECT shipment_id, 'Picked_Up', created_at + INTERVAL '6 hours', 'Lviv Regional Hub' FROM shipments
UNION ALL
SELECT shipment_id, 'Customs_In', created_at + INTERVAL '18 hours', customs_hub FROM shipments
UNION ALL
-- Inject prolonged customs dwell times (48-77 hours) specifically at Jagodzin-Dorohusk Hub
SELECT 
    shipment_id, 
    'Customs_Cleared', 
    created_at + INTERVAL '18 hours' + 
    CASE 
        WHEN customs_hub = 'Jagodzin-Dorohusk Hub' THEN INTERVAL '48 hours' + ((shipment_id % 30) * INTERVAL '1 hour')
        ELSE INTERVAL '8 hours' + ((shipment_id % 10) * INTERVAL '1 hour')
    END,
    customs_hub 
FROM shipments
UNION ALL
SELECT 
    shipment_id, 
    'Last_Mile_Hub', 
    created_at + INTERVAL '36 hours' + 
    CASE 
        WHEN customs_hub = 'Jagodzin-Dorohusk Hub' THEN INTERVAL '48 hours' + ((shipment_id % 30) * INTERVAL '1 hour')
        ELSE INTERVAL '8 hours' + ((shipment_id % 10) * INTERVAL '1 hour')
    END,
    destination_country || ' Central Hub'
FROM shipments
UNION ALL
SELECT 
    shipment_id, 
    'Delivered', 
    created_at + INTERVAL '54 hours' + 
    CASE 
        WHEN customs_hub = 'Jagodzin-Dorohusk Hub' THEN INTERVAL '48 hours' + ((shipment_id % 30) * INTERVAL '1 hour')
        ELSE INTERVAL '8 hours' + ((shipment_id % 10) * INTERVAL '1 hour')
    END,
    destination_country || ' Parcel Locker'
FROM shipments;

-- Inject duplicate tracking logs (simulating real-world barcode scanner double-scans)
INSERT INTO tracking_events (shipment_id, status, event_timestamp, hub_location)
SELECT shipment_id, 'Customs_In', event_timestamp + INTERVAL '5 minutes', hub_location
FROM tracking_events
WHERE status = 'Customs_In' AND shipment_id % 7 = 0;
