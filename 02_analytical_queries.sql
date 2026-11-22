/* ============================================================================
   PROJECT: International Logistics & Last-Mile Delivery Bottleneck Analysis
   FILE: 02_analytical_queries.sql
   AUTHOR: Viktoriia Sobolta
   DIALECT: PostgreSQL 14+
   PREREQUISITE: Execute 01_schema_and_seed_data.sql first.
   DESCRIPTION:
   Step 2 of the analytical pipeline. Contains production-style SQL queries:
     1. Data Cleaning & Stage Dwell Time (CTEs, ROW_NUMBER, LAG, p50/p95)
     2. Customs Hub Bottleneck & On-Time Delivery SLA Impact
     3. Carrier Unit Cost (EUR/kg), Transit Speed & DSO Financial Analysis
     4. Reusable SQL View (vw_logistics_kpi_summary) for Power BI integration
   ============================================================================ */

-- ----------------------------------------------------------------------------
-- QUERY 1: Data Cleaning & Stage-by-Stage Dwell Time Analysis
-- Business Goal: Remove duplicate scanner logs and measure average, median,
--                and 95th percentile (p95) hours spent in each transit stage.
-- SQL Skills: Common Table Expressions (CTEs), ROW_NUMBER(), LAG(), EPOCH,
--             PERCENTILE_CONT().
-- ----------------------------------------------------------------------------
WITH deduplicated_events AS (
    SELECT 
        event_id,
        shipment_id,
        status,
        event_timestamp,
        hub_location,
        -- Keep only the earliest scan per shipment and status to eliminate double-scans
        ROW_NUMBER() OVER (
            PARTITION BY shipment_id, status 
            ORDER BY event_timestamp ASC
        ) AS scan_rank
    FROM tracking_events
),
stage_transitions AS (
    SELECT 
        shipment_id,
        status AS current_stage,
        LAG(status) OVER (PARTITION BY shipment_id ORDER BY event_timestamp) AS previous_stage,
        LAG(event_timestamp) OVER (PARTITION BY shipment_id ORDER BY event_timestamp) AS stage_start_time,
        event_timestamp AS stage_end_time,
        ROUND(
            EXTRACT(EPOCH FROM (
                event_timestamp - LAG(event_timestamp) OVER (PARTITION BY shipment_id ORDER BY event_timestamp)
            )) / 3600.0, 2
        ) AS stage_duration_hours
    FROM deduplicated_events
    WHERE scan_rank = 1
)
SELECT 
    previous_stage || ' -> ' || current_stage AS process_step,
    COUNT(*) AS total_parcels,
    ROUND(AVG(stage_duration_hours), 2) AS avg_hours,
    ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY stage_duration_hours)::NUMERIC, 2) AS median_hours,
    ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY stage_duration_hours)::NUMERIC, 2) AS p95_hours
FROM stage_transitions
WHERE previous_stage IS NOT NULL
GROUP BY previous_stage, current_stage
ORDER BY p95_hours DESC;


-- ----------------------------------------------------------------------------
-- QUERY 2: Customs Hub Bottleneck & SLA Compliance Impact
-- Business Goal: Identify which customs checkpoints drive extreme tail delays
--                (p95) and quantify their impact on On-Time Delivery (OTD %).
-- SQL Skills: DISTINCT ON deduplication, multi-join self-pivoting, conditional
--             aggregation (CASE WHEN).
-- ----------------------------------------------------------------------------
WITH clean_events AS (
    SELECT DISTINCT ON (shipment_id, status)
        shipment_id,
        status,
        event_timestamp
    FROM tracking_events
    ORDER BY shipment_id, status, event_timestamp ASC
),
customs_dwell AS (
    SELECT 
        s.shipment_id,
        s.customs_hub,
        s.destination_country,
        s.promised_delivery_at,
        EXTRACT(EPOCH FROM (c_out.event_timestamp - c_in.event_timestamp)) / 3600.0 AS customs_hours,
        del.event_timestamp AS actual_delivery_at
    FROM shipments s
    JOIN clean_events c_in ON s.shipment_id = c_in.shipment_id AND c_in.status = 'Customs_In'
    JOIN clean_events c_out ON s.shipment_id = c_out.shipment_id AND c_out.status = 'Customs_Cleared'
    JOIN clean_events del ON s.shipment_id = del.shipment_id AND del.status = 'Delivered'
)
SELECT 
    customs_hub,
    COUNT(shipment_id) AS shipments_processed,
    ROUND(AVG(customs_hours)::NUMERIC, 1) AS avg_customs_hours,
    ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY customs_hours)::NUMERIC, 1) AS p95_customs_hours,
    ROUND(
        100.0 * SUM(CASE WHEN actual_delivery_at <= promised_delivery_at THEN 1 ELSE 0 END) / COUNT(*), 
        1
    ) AS on_time_delivery_pct
FROM customs_dwell
GROUP BY customs_hub
ORDER BY p95_customs_hours DESC;


-- ----------------------------------------------------------------------------
-- QUERY 3: Carrier Unit Cost, Transit Performance & DSO Financial Metrics
-- Business Goal: Evaluate carrier cost-efficiency (EUR/kg) against target SLA
--                and track Days Sales Outstanding (DSO) on B2B invoices.
-- SQL Skills: Multi-table joins, NULL handling with COALESCE, financial KPI
--             aggregation.
-- ----------------------------------------------------------------------------
WITH delivery_timestamps AS (
    SELECT 
        shipment_id,
        MIN(CASE WHEN status = 'Order_Created' THEN event_timestamp END) AS created_ts,
        MAX(CASE WHEN status = 'Delivered' THEN event_timestamp END) AS delivered_ts
    FROM tracking_events
    GROUP BY shipment_id
)
SELECT 
    c.carrier_name,
    s.destination_country,
    COUNT(s.shipment_id) AS total_shipments,
    ROUND(SUM(s.freight_cost_eur) / SUM(s.weight_kg), 2) AS cost_per_kg_eur,
    ROUND(AVG(EXTRACT(EPOCH FROM (dt.delivered_ts - dt.created_ts)) / 3600.0)::NUMERIC, 1) AS avg_total_transit_hours,
    c.sla_transit_hours AS target_sla_hours,
    ROUND(
        AVG(COALESCE(s.invoice_paid_at, CURRENT_DATE) - s.invoice_issued_at)::NUMERIC, 
        1
    ) AS avg_dso_days
FROM shipments s
JOIN carriers c ON s.carrier_id = c.carrier_id
JOIN delivery_timestamps dt ON s.shipment_id = dt.shipment_id
GROUP BY c.carrier_name, s.destination_country, c.sla_transit_hours
ORDER BY avg_dso_days DESC, cost_per_kg_eur DESC;


-- ----------------------------------------------------------------------------
-- QUERY 4: BI Reporting Layer (SQL View for Power BI)
-- Business Goal: Provide a clean, denormalized analytical view combining
--                operational stage durations, OTD flags, and financial KPIs.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_logistics_kpi_summary AS
WITH clean_logs AS (
    SELECT 
        shipment_id,
        status,
        MIN(event_timestamp) AS clean_ts
    FROM tracking_events
    GROUP BY shipment_id, status
)
SELECT 
    s.shipment_id,
    s.tracking_number,
    c.carrier_name,
    s.origin_country,
    s.destination_country,
    s.customs_hub,
    s.weight_kg,
    s.freight_cost_eur,
    s.invoice_amount_eur,
    ROUND(s.freight_cost_eur / NULLIF(s.weight_kg, 0), 2) AS unit_cost_per_kg,
    ROUND(EXTRACT(EPOCH FROM (cc.clean_ts - ci.clean_ts)) / 3600.0, 2) AS customs_clearance_hours,
    ROUND(EXTRACT(EPOCH FROM (dl.clean_ts - lm.clean_ts)) / 3600.0, 2) AS last_mile_hours,
    ROUND(EXTRACT(EPOCH FROM (dl.clean_ts - oc.clean_ts)) / 3600.0, 2) AS end_to_end_transit_hours,
    CASE WHEN dl.clean_ts <= s.promised_delivery_at THEN 1 ELSE 0 END AS is_on_time,
    (COALESCE(s.invoice_paid_at, CURRENT_DATE) - s.invoice_issued_at) AS dso_days,
    CASE WHEN s.invoice_paid_at IS NULL THEN 'Open' ELSE 'Paid' END AS payment_status
FROM shipments s
JOIN carriers c ON s.carrier_id = c.carrier_id
LEFT JOIN clean_logs oc ON s.shipment_id = oc.shipment_id AND oc.status = 'Order_Created'
LEFT JOIN clean_logs ci ON s.shipment_id = ci.shipment_id AND ci.status = 'Customs_In'
LEFT JOIN clean_logs cc ON s.shipment_id = cc.shipment_id AND cc.status = 'Customs_Cleared'
LEFT JOIN clean_logs lm ON s.shipment_id = lm.shipment_id AND lm.status = 'Last_Mile_Hub'
LEFT JOIN clean_logs dl ON s.shipment_id = dl.shipment_id AND dl.status = 'Delivered';

-- Preview final analytical view
SELECT * FROM vw_logistics_kpi_summary LIMIT 15;
