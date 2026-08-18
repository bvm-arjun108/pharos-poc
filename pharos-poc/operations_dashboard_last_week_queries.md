# Operations Reporting & Transformation Control Dashboard

## Last-Week SQL Query Pack

**Period:** Previous completed Monday--Sunday week. As of August 18,
2026: **August 10--16, 2026**.

This query pack covers the five-table operations dashboard using: -
`rule_hit` - `rule_hit_reconciliation` - `rule_hit_exclusion_audit` -
`record_transformation_journey` - `report_transformation_reconciliation`

> Historical metrics should be evaluated as of the selected period end
> where applicable.

## 0. Common Date Parameters

``` sql
WITH params AS (
    SELECT
        (date_trunc('week', CURRENT_DATE)::date - 7) AS start_date,
        (date_trunc('week', CURRENT_DATE)::date - 1) AS end_date
)
SELECT * FROM params;
```

## 1. Main Summary + Reporting Health

``` sql
WITH params AS (
    SELECT
        (date_trunc('week', CURRENT_DATE)::date - 7) AS start_date,
        (date_trunc('week', CURRENT_DATE)::date - 1) AS end_date
),
weekly_rule_hits AS (
    SELECT rh.*
    FROM rule_hit rh
    CROSS JOIN params p
    WHERE rh.transaction_date >= p.start_date
      AND rh.transaction_date < p.end_date + INTERVAL '1 day'
)
SELECT
    COUNT(*) AS total_rule_hits,
    COUNT(*) FILTER (WHERE exclusion_reason_id IS NOT NULL) AS excluded_hits,
    COUNT(*) FILTER (WHERE exclusion_reason_id IS NULL) AS requires_reporting,
    COUNT(*) FILTER (
        WHERE exclusion_reason_id IS NULL
          AND reporting_timestamp IS NOT NULL
          AND reporting_timestamp < (SELECT end_date + INTERVAL '1 day' FROM params)
    ) AS reported_hits,
    COUNT(*) FILTER (
        WHERE exclusion_reason_id IS NULL
          AND (reporting_timestamp IS NULL OR reporting_timestamp >=
              (SELECT end_date + INTERVAL '1 day' FROM params))
    ) AS still_open,
    ROUND(
        100.0 * COUNT(*) FILTER (
            WHERE exclusion_reason_id IS NULL
              AND reporting_timestamp IS NOT NULL
              AND reporting_timestamp < (SELECT end_date + INTERVAL '1 day' FROM params)
        ) / NULLIF(COUNT(*) FILTER (WHERE exclusion_reason_id IS NULL), 0), 2
    ) AS reported_pct
FROM weekly_rule_hits;
```

Expected controls: `Total Rule Hits = Excluded + Requires Reporting`
`Requires Reporting = Reported + Still Open`

## 2. Open Backlog and Aging as of Week End

``` sql
WITH params AS (
    SELECT
        (date_trunc('week', CURRENT_DATE)::date - 7) AS start_date,
        (date_trunc('week', CURRENT_DATE)::date - 1) AS end_date
)
SELECT
    COUNT(*) AS total_open_backlog,
    COUNT(*) FILTER (WHERE (p.end_date-rh.transaction_date::date) BETWEEN 0 AND 3) AS open_0_3_days,
    COUNT(*) FILTER (WHERE (p.end_date-rh.transaction_date::date) BETWEEN 4 AND 7) AS open_4_7_days,
    COUNT(*) FILTER (WHERE (p.end_date-rh.transaction_date::date) BETWEEN 8 AND 14) AS open_8_14_days,
    COUNT(*) FILTER (WHERE (p.end_date-rh.transaction_date::date) BETWEEN 15 AND 30) AS open_15_30_days,
    COUNT(*) FILTER (WHERE (p.end_date-rh.transaction_date::date) > 30) AS open_30_plus_days,
    MAX(p.end_date-rh.transaction_date::date) AS oldest_open_days
FROM rule_hit rh
CROSS JOIN params p
WHERE rh.transaction_date::date <= p.end_date
  AND rh.exclusion_reason_id IS NULL
  AND (rh.reporting_timestamp IS NULL
       OR rh.reporting_timestamp >= p.end_date + INTERVAL '1 day');
```

## 3. Reporting Balance Validation

``` sql
WITH params AS (
    SELECT date_trunc('week',CURRENT_DATE)::date-7 AS start_date,
           date_trunc('week',CURRENT_DATE)::date-1 AS end_date
),
m AS (
    SELECT
        COUNT(*) AS total_hits,
        COUNT(*) FILTER (WHERE exclusion_reason_id IS NOT NULL) AS excluded,
        COUNT(*) FILTER (WHERE exclusion_reason_id IS NULL) AS requires_reporting,
        COUNT(*) FILTER (
            WHERE exclusion_reason_id IS NULL
              AND reporting_timestamp IS NOT NULL
              AND reporting_timestamp < p.end_date + INTERVAL '1 day'
        ) AS reported,
        COUNT(*) FILTER (
            WHERE exclusion_reason_id IS NULL
              AND (reporting_timestamp IS NULL
                   OR reporting_timestamp >= p.end_date + INTERVAL '1 day')
        ) AS open
    FROM rule_hit rh CROSS JOIN params p
    WHERE rh.transaction_date >= p.start_date
      AND rh.transaction_date < p.end_date + INTERVAL '1 day'
)
SELECT *,
       total_hits-(excluded+requires_reporting) AS rule_hit_balance_diff,
       requires_reporting-(reported+open) AS reporting_balance_diff
FROM m;
```

Both differences should equal `0`.

## 4. Processing Exceptions KPI

Definition: `Missing Attempts + Transformation Failures`.

``` sql
WITH params AS (
    SELECT date_trunc('week',CURRENT_DATE)::date-7 AS start_date,
           date_trunc('week',CURRENT_DATE)::date-1 AS end_date
),
latest_batch_run AS (
    SELECT * FROM (
        SELECT r.*,
               ROW_NUMBER() OVER (
                   PARTITION BY r.batch_id,r.rpt_grp_id
                   ORDER BY r.seq_no DESC,r.modified_timestamp DESC
               ) AS rn
        FROM report_transformation_reconciliation r
        CROSS JOIN params p
        WHERE r.created_timestamp >= p.start_date
          AND r.created_timestamp < p.end_date + INTERVAL '1 day'
    ) x WHERE rn=1
)
SELECT
    SUM(COALESCE(txn_missing_attempt_count,0)) AS missing_attempts,
    SUM(COALESCE(activity_transformation_failed,0)) AS transformation_failures,
    SUM(COALESCE(txn_missing_attempt_count,0)
       +COALESCE(activity_transformation_failed,0)) AS processing_exceptions
FROM latest_batch_run;
```

## 5. Transformation Process Flow

``` sql
WITH params AS (
    SELECT date_trunc('week',CURRENT_DATE)::date-7 AS start_date,
           date_trunc('week',CURRENT_DATE)::date-1 AS end_date
),
latest_batch_run AS (
    SELECT * FROM (
        SELECT r.*,
               ROW_NUMBER() OVER (
                   PARTITION BY batch_id,rpt_grp_id
                   ORDER BY seq_no DESC,modified_timestamp DESC
               ) rn
        FROM report_transformation_reconciliation r
        CROSS JOIN params p
        WHERE created_timestamp >= p.start_date
          AND created_timestamp < p.end_date + INTERVAL '1 day'
    ) x WHERE rn=1
)
SELECT
    SUM(txn_selected) AS selected_for_processing,
    SUM(excluded_txn) AS excluded_txn,
    SUM(already_reported_count) AS already_reported,
    SUM(COALESCE(excluded_txn,0)+COALESCE(already_reported_count,0)) AS filtered_not_eligible,
    SUM(txn_missing_attempt_count) AS join_errors,
    SUM(expected_reportable_txn) AS expected_reportable,
    SUM(actual_reportable_txn) AS actual_reportable,
    SUM(activity_transformed) AS transformation_success,
    SUM(activity_transformation_failed) AS transformation_failed,
    SUM(duplicate_transformation) AS duplicate_transformation,
    SUM(soft_dedup_dropped_txn_count) AS soft_dedup_dropped
FROM latest_batch_run;
```

## 6. Reconciliation Issues KPI

Controls: 1. `expected_reportable_txn = actual_reportable_txn` 2.
`expected_activity_eligible_for_transformation = actual_activity_eligible_for_transformation`
3.
`actual_activity_eligible_for_transformation = activity_transformed + activity_transformation_failed + duplicate_transformation`

``` sql
WITH params AS (
    SELECT date_trunc('week',CURRENT_DATE)::date-7 AS start_date,
           date_trunc('week',CURRENT_DATE)::date-1 AS end_date
),
latest_batch_run AS (
    SELECT * FROM (
        SELECT r.*,
               ROW_NUMBER() OVER (
                   PARTITION BY batch_id,rpt_grp_id
                   ORDER BY seq_no DESC,modified_timestamp DESC
               ) rn
        FROM report_transformation_reconciliation r
        CROSS JOIN params p
        WHERE created_timestamp >= p.start_date
          AND created_timestamp < p.end_date + INTERVAL '1 day'
    ) x WHERE rn=1
),
recon AS (
    SELECT batch_id,rpt_grp_id,rpt_grp_name,
           expected_reportable_txn-actual_reportable_txn AS reportable_diff,
           expected_activity_eligible_for_transformation
             -actual_activity_eligible_for_transformation AS activity_eligibility_diff,
           actual_activity_eligible_for_transformation
             -(COALESCE(activity_transformed,0)
              +COALESCE(activity_transformation_failed,0)
              +COALESCE(duplicate_transformation,0)) AS transformation_disposition_diff
    FROM latest_batch_run
)
SELECT
    COUNT(*) FILTER (
        WHERE reportable_diff<>0 OR activity_eligibility_diff<>0
           OR transformation_disposition_diff<>0
    ) AS reconciliation_issues,
    COUNT(DISTINCT rpt_grp_id) FILTER (
        WHERE reportable_diff<>0 OR activity_eligibility_diff<>0
           OR transformation_disposition_diff<>0
    ) AS affected_report_groups,
    COUNT(DISTINCT batch_id) FILTER (
        WHERE reportable_diff<>0 OR activity_eligibility_diff<>0
           OR transformation_disposition_diff<>0
    ) AS affected_batches
FROM recon;
```

## 7. Reconciliation Issue Detail

``` sql
WITH params AS (
    SELECT date_trunc('week',CURRENT_DATE)::date-7 AS start_date,
           date_trunc('week',CURRENT_DATE)::date-1 AS end_date
),
latest_batch_run AS (
    SELECT * FROM (
        SELECT r.*,
               ROW_NUMBER() OVER (
                   PARTITION BY batch_id,rpt_grp_id
                   ORDER BY seq_no DESC,modified_timestamp DESC
               ) rn
        FROM report_transformation_reconciliation r
        CROSS JOIN params p
        WHERE created_timestamp >= p.start_date
          AND created_timestamp < p.end_date + INTERVAL '1 day'
    ) x WHERE rn=1
)
SELECT
    batch_id,rpt_grp_id,rpt_grp_name,
    expected_reportable_txn,actual_reportable_txn,
    expected_reportable_txn-actual_reportable_txn AS reportable_diff,
    expected_activity_eligible_for_transformation,
    actual_activity_eligible_for_transformation,
    expected_activity_eligible_for_transformation
      -actual_activity_eligible_for_transformation AS eligibility_diff,
    activity_transformed,activity_transformation_failed,duplicate_transformation,
    actual_activity_eligible_for_transformation
      -(COALESCE(activity_transformed,0)
       +COALESCE(activity_transformation_failed,0)
       +COALESCE(duplicate_transformation,0)) AS transformation_diff
FROM latest_batch_run
WHERE expected_reportable_txn<>actual_reportable_txn
   OR expected_activity_eligible_for_transformation<>actual_activity_eligible_for_transformation
   OR actual_activity_eligible_for_transformation<>
      (COALESCE(activity_transformed,0)
       +COALESCE(activity_transformation_failed,0)
       +COALESCE(duplicate_transformation,0))
ORDER BY rpt_grp_name,batch_id;
```

## 8. Top Exclusion Reasons

``` sql
WITH params AS (
    SELECT date_trunc('week',CURRENT_DATE)::date-7 AS start_date,
           date_trunc('week',CURRENT_DATE)::date-1 AS end_date
)
SELECT
    exclusion_reason_id,
    COUNT(*) AS excluded_hits,
    ROUND(100.0*COUNT(*)/NULLIF(SUM(COUNT(*)) OVER (),0),2) AS pct_of_excluded
FROM rule_hit rh CROSS JOIN params p
WHERE rh.transaction_date>=p.start_date
  AND rh.transaction_date<p.end_date+INTERVAL '1 day'
  AND exclusion_reason_id IS NOT NULL
GROUP BY exclusion_reason_id
ORDER BY excluded_hits DESC;
```

## 9. Exclusion Audit Summary

``` sql
WITH params AS (
    SELECT date_trunc('week',CURRENT_DATE)::date-7 AS start_date,
           date_trunc('week',CURRENT_DATE)::date-1 AS end_date
)
SELECT exclusion_reason_id,exclusion_strategy,COUNT(*) AS excluded_count
FROM rule_hit_exclusion_audit a CROSS JOIN params p
WHERE a.created_timestamp>=p.start_date
  AND a.created_timestamp<p.end_date+INTERVAL '1 day'
GROUP BY exclusion_reason_id,exclusion_strategy
ORDER BY excluded_count DESC;
```

## 10. Report Group Weekly Reporting Health

``` sql
WITH params AS (
    SELECT date_trunc('week',CURRENT_DATE)::date-7 AS start_date,
           date_trunc('week',CURRENT_DATE)::date-1 AS end_date
)
SELECT
    rh.rpt_grp_id,rh.rpt_grp_name,
    COUNT(*) AS total_rule_hits,
    COUNT(*) FILTER (WHERE exclusion_reason_id IS NOT NULL) AS excluded,
    COUNT(*) FILTER (WHERE exclusion_reason_id IS NULL) AS requires_reporting,
    COUNT(*) FILTER (
        WHERE exclusion_reason_id IS NULL AND reporting_timestamp IS NOT NULL
          AND reporting_timestamp<p.end_date+INTERVAL '1 day'
    ) AS reported,
    COUNT(*) FILTER (
        WHERE exclusion_reason_id IS NULL
          AND (reporting_timestamp IS NULL
               OR reporting_timestamp>=p.end_date+INTERVAL '1 day')
    ) AS still_open
FROM rule_hit rh CROSS JOIN params p
WHERE rh.transaction_date>=p.start_date
  AND rh.transaction_date<p.end_date+INTERVAL '1 day'
GROUP BY rh.rpt_grp_id,rh.rpt_grp_name
ORDER BY still_open DESC;
```

## 11. Report Group Backlog Health

``` sql
WITH params AS (
    SELECT date_trunc('week',CURRENT_DATE)::date-7 AS start_date,
           date_trunc('week',CURRENT_DATE)::date-1 AS end_date
)
SELECT
    rh.rpt_grp_id,rh.rpt_grp_name,
    COUNT(*) AS still_open,
    COUNT(*) FILTER (WHERE (p.end_date-rh.transaction_date::date)>30) AS open_over_30_days,
    MAX(p.end_date-rh.transaction_date::date) AS oldest_open_days
FROM rule_hit rh CROSS JOIN params p
WHERE rh.transaction_date::date<=p.end_date
  AND rh.exclusion_reason_id IS NULL
  AND (rh.reporting_timestamp IS NULL
       OR rh.reporting_timestamp>=p.end_date+INTERVAL '1 day')
GROUP BY rh.rpt_grp_id,rh.rpt_grp_name
ORDER BY open_over_30_days DESC,still_open DESC;
```

## 12. Transformation Health by Report Group

``` sql
WITH params AS (
    SELECT date_trunc('week',CURRENT_DATE)::date-7 AS start_date,
           date_trunc('week',CURRENT_DATE)::date-1 AS end_date
),
latest AS (
    SELECT * FROM (
        SELECT r.*,
               ROW_NUMBER() OVER (
                   PARTITION BY batch_id,rpt_grp_id
                   ORDER BY seq_no DESC,modified_timestamp DESC
               ) rn
        FROM report_transformation_reconciliation r CROSS JOIN params p
        WHERE created_timestamp>=p.start_date
          AND created_timestamp<p.end_date+INTERVAL '1 day'
    ) x WHERE rn=1
)
SELECT
    rpt_grp_id,rpt_grp_name,
    SUM(txn_selected) AS txn_selected,
    SUM(excluded_txn) AS excluded_txn,
    SUM(already_reported_count) AS already_reported,
    SUM(txn_missing_attempt_count) AS join_errors,
    SUM(expected_reportable_txn) AS expected_reportable,
    SUM(actual_reportable_txn) AS actual_reportable,
    SUM(activity_transformed) AS transformed,
    SUM(activity_transformation_failed) AS transform_failed,
    SUM(expected_reportable_txn-actual_reportable_txn) AS reportable_recon_diff
FROM latest
GROUP BY rpt_grp_id,rpt_grp_name
ORDER BY transform_failed DESC,join_errors DESC;
```

## 13. Batch Health

``` sql
WITH params AS (
    SELECT date_trunc('week',CURRENT_DATE)::date-7 AS start_date,
           date_trunc('week',CURRENT_DATE)::date-1 AS end_date
),
latest AS (
    SELECT * FROM (
        SELECT r.*,
               ROW_NUMBER() OVER (
                   PARTITION BY batch_id,rpt_grp_id
                   ORDER BY seq_no DESC,modified_timestamp DESC
               ) rn
        FROM report_transformation_reconciliation r CROSS JOIN params p
        WHERE created_timestamp>=p.start_date
          AND created_timestamp<p.end_date+INTERVAL '1 day'
    ) x WHERE rn=1
)
SELECT
    batch_id,rpt_grp_id,rpt_grp_name,
    txn_selected AS selected,
    COALESCE(excluded_txn,0)+COALESCE(already_reported_count,0) AS filtered_not_eligible,
    txn_missing_attempt_count AS join_errors,
    expected_reportable_txn AS eligible,
    activity_transformed AS success,
    activity_transformation_failed AS failed,
    COALESCE(txn_missing_attempt_count,0)
      +COALESCE(activity_transformation_failed,0) AS needs_attention,
    expected_reportable_txn-actual_reportable_txn AS reconciliation_diff,
    modified_timestamp AS last_updated
FROM latest
ORDER BY needs_attention DESC,
         ABS(expected_reportable_txn-actual_reportable_txn) DESC,
         modified_timestamp DESC;
```

## 14. Processing Exception Breakdown

``` sql
WITH params AS (
    SELECT date_trunc('week',CURRENT_DATE)::date-7 AS start_date,
           date_trunc('week',CURRENT_DATE)::date-1 AS end_date
),
latest AS (
    SELECT * FROM (
        SELECT r.*,
               ROW_NUMBER() OVER (
                   PARTITION BY batch_id,rpt_grp_id
                   ORDER BY seq_no DESC,modified_timestamp DESC
               ) rn
        FROM report_transformation_reconciliation r CROSS JOIN params p
        WHERE created_timestamp>=p.start_date
          AND created_timestamp<p.end_date+INTERVAL '1 day'
    ) x WHERE rn=1
)
SELECT
    SUM(txn_missing_attempt_count) AS attempt_not_received,
    SUM(activity_transformation_failed) AS transformation_failed,
    SUM(txn_missing_attempt_count)+SUM(activity_transformation_failed)
        AS total_processing_exceptions
FROM latest;
```

## 15. Validate Exceptions Against `record_transformation_journey`

Run this before hard-coding exact stage/status/skip-reason values in
transaction drill-downs.

``` sql
WITH params AS (
    SELECT date_trunc('week',CURRENT_DATE)::date-7 AS start_date,
           date_trunc('week',CURRENT_DATE)::date-1 AS end_date
)
SELECT stage,status,skip_reason,COUNT(*) AS record_count
FROM record_transformation_journey j CROSS JOIN params p
WHERE j.created_timestamp>=p.start_date
  AND j.created_timestamp<p.end_date+INTERVAL '1 day'
GROUP BY stage,status,skip_reason
ORDER BY stage,status,record_count DESC;
```

## 16. Daily Reporting Trend

``` sql
WITH params AS (
    SELECT date_trunc('week',CURRENT_DATE)::date-7 AS start_date,
           date_trunc('week',CURRENT_DATE)::date-1 AS end_date
)
SELECT
    transaction_date::date AS day,
    COUNT(*) FILTER (WHERE exclusion_reason_id IS NULL) AS requires_reporting,
    COUNT(*) FILTER (
        WHERE exclusion_reason_id IS NULL
          AND reporting_timestamp IS NOT NULL
          AND reporting_timestamp<p.end_date+INTERVAL '1 day'
    ) AS reported,
    COUNT(*) FILTER (
        WHERE exclusion_reason_id IS NULL
          AND (reporting_timestamp IS NULL
               OR reporting_timestamp>=p.end_date+INTERVAL '1 day')
    ) AS open
FROM rule_hit rh CROSS JOIN params p
WHERE transaction_date>=p.start_date
  AND transaction_date<p.end_date+INTERVAL '1 day'
GROUP BY transaction_date::date
ORDER BY day;
```

# Recommended Initial Execution Order

1.  Query 1 --- Main Summary + Reporting Health
2.  Query 2 --- Open Backlog & Aging
3.  Query 3 --- Reporting Balance Validation
4.  Query 4 --- Processing Exceptions
5.  Query 5 --- Transformation Process Flow
6.  Query 6 --- Reconciliation Issues
7.  Queries 10 & 11 --- Report Group Health
8.  Query 13 --- Batch Health
9.  Query 15 --- Journey Stage/Status Validation

# Dashboard Metric → Source Mapping

  ----------------------------------------------------------------------------
  Dashboard Area                      Primary Source
  ----------------------------------- ----------------------------------------
  Total Rule Hits                     `rule_hit`

  Excluded                            `rule_hit`

  Requires Reporting                  `rule_hit`

  Reported                            `rule_hit`

  Still Open                          `rule_hit`

  Backlog Aging                       `rule_hit`

  Top Exclusion Reasons               `rule_hit`

  Exclusion Details                   `rule_hit_exclusion_audit`

  Processing Exceptions               `report_transformation_reconciliation`

  Transformation Flow                 `report_transformation_reconciliation`

  Reconciliation Issues               `report_transformation_reconciliation`

  Report Group Reporting Health       `rule_hit`

  Report Group Processing Health      `report_transformation_reconciliation`

  Batch Health                        `report_transformation_reconciliation`

  Transaction Journey / Root Cause    `record_transformation_journey`
  ----------------------------------------------------------------------------
