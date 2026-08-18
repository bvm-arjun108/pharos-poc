# Operations Reporting & Transformation Control Dashboard

## Dashboard SQL Query Catalog

> **Purpose:** Query catalog for the reconciliation-first Operations
> dashboard based on the five-table design discussed.
>
> **Primary principle:** Top-level reporting health should come from
> reconciliation/control tables. Detail tables should primarily support
> investigation and drill-down.
>
> **Important:** The screenshots established useful column names and
> sample behavior, but not every business-semantic relationship is fully
> proven. Queries marked **VALIDATE** should not be promoted to
> production KPI logic until the field semantics/grain are confirmed
> with the data owners.

------------------------------------------------------------------------

## 0. Standard Reporting Period

### Question answered

**What period is every dashboard query using?**

The example below uses the **previous completed calendar week
(Monday--Sunday)**.

``` sql
WITH params AS (
    SELECT
        (date_trunc('week', CURRENT_DATE)::date - 7) AS start_date,
        (date_trunc('week', CURRENT_DATE)::date - 1) AS end_date
)
SELECT * FROM params;
```

Use the same `start_date` and `end_date` parameters across the dashboard
so cards and drill-downs remain reconcilable.

------------------------------------------------------------------------

# 1. Reporting Health

The main reporting KPIs should be driven primarily by
`rule_hit_reconciliation`, not by `rule_hit.is_reported`.

## 1.1 Latest Rule-Hit Reconciliation Run

### Question answered

**For each report group/run date, which reconciliation record represents
the latest calculation?**

This prevents older reconciliation iterations from being double counted.

``` sql
WITH params AS (
    SELECT
        date_trunc('week', CURRENT_DATE)::date - 7 AS start_date,
        date_trunc('week', CURRENT_DATE)::date - 1 AS end_date
),
latest_recon AS (
    SELECT *
    FROM (
        SELECT
            r.*,
            ROW_NUMBER() OVER (
                PARTITION BY r.rpt_grp_id, r.run_date
                ORDER BY r.seq_no DESC, r.modified_timestamp DESC
            ) AS rn
        FROM rule_hit_reconciliation r
        CROSS JOIN params p
        WHERE r.run_date >= p.start_date
          AND r.run_date < p.end_date + INTERVAL '1 day'
    ) x
    WHERE rn = 1
)
SELECT *
FROM latest_recon;
```

> If `run_date` is stored as an integer/string such as `20260715` rather
> than a PostgreSQL date, normalize it first with the appropriate
> conversion for the actual datatype.

------------------------------------------------------------------------

## 1.2 Expected Rule Hits

### Question answered

**How many distinct rule hits were expected by the upstream/IWRA side
during the selected period?**

### Dashboard

`Expected Rule Hits`

``` sql
WITH params AS (
    SELECT
        date_trunc('week', CURRENT_DATE)::date - 7 AS start_date,
        date_trunc('week', CURRENT_DATE)::date - 1 AS end_date
),
latest_recon AS (
    SELECT *
    FROM (
        SELECT
            r.*,
            ROW_NUMBER() OVER (
                PARTITION BY r.rpt_grp_id, r.run_date
                ORDER BY r.seq_no DESC, r.modified_timestamp DESC
            ) rn
        FROM rule_hit_reconciliation r
        CROSS JOIN params p
        WHERE r.run_date >= p.start_date
          AND r.run_date < p.end_date + INTERVAL '1 day'
    ) x
    WHERE rn = 1
)
SELECT
    SUM(COALESCE(distinct_rule_hits_count_iwra, 0)) AS expected_rule_hits
FROM latest_recon;
```

------------------------------------------------------------------------

## 1.3 Matched Rule Hits

### Question answered

**Of the rule hits expected upstream, how many were found/matched in
Pharos?**

### Dashboard

`Matched / Reported`

``` sql
WITH params AS (
    SELECT
        date_trunc('week', CURRENT_DATE)::date - 7 AS start_date,
        date_trunc('week', CURRENT_DATE)::date - 1 AS end_date
),
latest_recon AS (
    SELECT *
    FROM (
        SELECT
            r.*,
            ROW_NUMBER() OVER (
                PARTITION BY r.rpt_grp_id, r.run_date
                ORDER BY r.seq_no DESC, r.modified_timestamp DESC
            ) rn
        FROM rule_hit_reconciliation r
        CROSS JOIN params p
        WHERE r.run_date >= p.start_date
          AND r.run_date < p.end_date + INTERVAL '1 day'
    ) x
    WHERE rn = 1
)
SELECT
    SUM(COALESCE(distinct_rule_hits_count_pharos, 0)) AS matched_rule_hits
FROM latest_recon;
```

> The dashboard label should preferably say **Matched Rule Hits** unless
> the business confirms that a Pharos reconciliation match is
> semantically identical to "reported."

------------------------------------------------------------------------

## 1.4 Missed Rule Hits

### Question answered

**How many expected rule hits were not found in Pharos?**

This is one of the most important operational exception KPIs.

### Dashboard

`Missed Rule Hits`

``` sql
WITH params AS (
    SELECT
        date_trunc('week', CURRENT_DATE)::date - 7 AS start_date,
        date_trunc('week', CURRENT_DATE)::date - 1 AS end_date
),
latest_recon AS (
    SELECT *
    FROM (
        SELECT
            r.*,
            ROW_NUMBER() OVER (
                PARTITION BY r.rpt_grp_id, r.run_date
                ORDER BY r.seq_no DESC, r.modified_timestamp DESC
            ) rn
        FROM rule_hit_reconciliation r
        CROSS JOIN params p
        WHERE r.run_date >= p.start_date
          AND r.run_date < p.end_date + INTERVAL '1 day'
    ) x
    WHERE rn = 1
)
SELECT
    SUM(COALESCE(missed_rule_hits_count_pharos, 0)) AS missed_rule_hits
FROM latest_recon;
```

------------------------------------------------------------------------

## 1.5 Rule-Hit Match Rate

### Question answered

**What percentage of expected rule hits successfully matched Pharos?**

``` sql
WITH params AS (
    SELECT
        date_trunc('week', CURRENT_DATE)::date - 7 AS start_date,
        date_trunc('week', CURRENT_DATE)::date - 1 AS end_date
),
latest_recon AS (
    SELECT *
    FROM (
        SELECT
            r.*,
            ROW_NUMBER() OVER (
                PARTITION BY r.rpt_grp_id, r.run_date
                ORDER BY r.seq_no DESC, r.modified_timestamp DESC
            ) rn
        FROM rule_hit_reconciliation r
        CROSS JOIN params p
        WHERE r.run_date >= p.start_date
          AND r.run_date < p.end_date + INTERVAL '1 day'
    ) x
    WHERE rn = 1
)
SELECT
    SUM(COALESCE(distinct_rule_hits_count_iwra, 0)) AS expected,
    SUM(COALESCE(distinct_rule_hits_count_pharos, 0)) AS matched,
    SUM(COALESCE(missed_rule_hits_count_pharos, 0)) AS missed,
    ROUND(
        100.0 * SUM(COALESCE(distinct_rule_hits_count_pharos, 0))
        / NULLIF(SUM(COALESCE(distinct_rule_hits_count_iwra, 0)), 0),
        2
    ) AS match_rate_pct
FROM latest_recon;
```

------------------------------------------------------------------------

# 2. Reporting Trend

## 2.1 Expected vs Matched vs Missed by Run Date

### Question answered

**Is reporting health improving or deteriorating over time, and on which
run did the mismatch appear?**

### Dashboard

`Reporting Reconciliation Trend`

``` sql
WITH params AS (
    SELECT
        date_trunc('week', CURRENT_DATE)::date - 7 AS start_date,
        date_trunc('week', CURRENT_DATE)::date - 1 AS end_date
),
latest_recon AS (
    SELECT *
    FROM (
        SELECT
            r.*,
            ROW_NUMBER() OVER (
                PARTITION BY r.rpt_grp_id, r.run_date
                ORDER BY r.seq_no DESC, r.modified_timestamp DESC
            ) rn
        FROM rule_hit_reconciliation r
        CROSS JOIN params p
        WHERE r.run_date >= p.start_date
          AND r.run_date < p.end_date + INTERVAL '1 day'
    ) x
    WHERE rn = 1
)
SELECT
    run_date,
    SUM(COALESCE(distinct_rule_hits_count_iwra, 0))   AS expected,
    SUM(COALESCE(distinct_rule_hits_count_pharos, 0)) AS matched,
    SUM(COALESCE(missed_rule_hits_count_pharos, 0))   AS missed
FROM latest_recon
GROUP BY run_date
ORDER BY run_date;
```

------------------------------------------------------------------------

# 3. Report Group Health

## 3.1 Reporting Health by Report Group

### Question answered

**Which report groups are responsible for missed rule hits?**

### Dashboard

`Report Group Health`

``` sql
WITH params AS (
    SELECT
        date_trunc('week', CURRENT_DATE)::date - 7 AS start_date,
        date_trunc('week', CURRENT_DATE)::date - 1 AS end_date
),
latest_recon AS (
    SELECT *
    FROM (
        SELECT
            r.*,
            ROW_NUMBER() OVER (
                PARTITION BY r.rpt_grp_id, r.run_date
                ORDER BY r.seq_no DESC, r.modified_timestamp DESC
            ) rn
        FROM rule_hit_reconciliation r
        CROSS JOIN params p
        WHERE r.run_date >= p.start_date
          AND r.run_date < p.end_date + INTERVAL '1 day'
    ) x
    WHERE rn = 1
)
SELECT
    rpt_grp_id,
    rpt_grp_name,
    SUM(COALESCE(distinct_rule_hits_count_iwra, 0)) AS expected,
    SUM(COALESCE(distinct_rule_hits_count_pharos, 0)) AS matched,
    SUM(COALESCE(missed_rule_hits_count_pharos, 0)) AS missed,
    ROUND(
        100.0 * SUM(COALESCE(distinct_rule_hits_count_pharos, 0))
        / NULLIF(SUM(COALESCE(distinct_rule_hits_count_iwra, 0)), 0),
        2
    ) AS match_rate_pct
FROM latest_recon
GROUP BY rpt_grp_id, rpt_grp_name
ORDER BY missed DESC, rpt_grp_name;
```

### Drill-down behavior

Clicking a report group should preserve:

-   `rpt_grp_id`
-   selected date/run range

and open the report-group detail page.

------------------------------------------------------------------------

## 3.2 Report-Group Run Detail

### Question answered

**For this report group, on which specific run did the mismatch occur?**

``` sql
WITH ranked AS (
    SELECT
        r.*,
        ROW_NUMBER() OVER (
            PARTITION BY r.rpt_grp_id, r.run_date
            ORDER BY r.seq_no DESC, r.modified_timestamp DESC
        ) rn
    FROM rule_hit_reconciliation r
    WHERE r.rpt_grp_id = :rpt_grp_id
      AND r.run_date >= :start_date
      AND r.run_date < :end_date + INTERVAL '1 day'
)
SELECT
    rpt_grp_id,
    rpt_grp_name,
    run_date,
    seq_no,
    distinct_rule_hits_count_iwra AS expected,
    distinct_rule_hits_count_pharos AS matched,
    missed_rule_hits_count_pharos AS missed,
    rule_hit_publish_count_iwra,
    modified_timestamp
FROM ranked
WHERE rn = 1
ORDER BY run_date DESC;
```

------------------------------------------------------------------------

# 4. Transformation Control

The transformation dashboard should be based on the **latest row for
each `batch_id + rpt_grp_id`**.

## 4.1 Latest Batch/Report-Group Reconciliation Record

### Question answered

**What is the final reconciliation state of each batch/report-group
run?**

``` sql
WITH params AS (
    SELECT
        date_trunc('week', CURRENT_DATE)::date - 7 AS start_date,
        date_trunc('week', CURRENT_DATE)::date - 1 AS end_date
),
latest_batch_run AS (
    SELECT *
    FROM (
        SELECT
            r.*,
            ROW_NUMBER() OVER (
                PARTITION BY r.batch_id, r.rpt_grp_id
                ORDER BY r.seq_no DESC, r.modified_timestamp DESC
            ) rn
        FROM report_transformation_reconciliation r
        CROSS JOIN params p
        WHERE r.created_timestamp >= p.start_date
          AND r.created_timestamp < p.end_date + INTERVAL '1 day'
    ) x
    WHERE rn = 1
)
SELECT *
FROM latest_batch_run;
```

------------------------------------------------------------------------

## 4.2 Transformation Summary

### Question answered

**What volume was selected, filtered, considered reportable,
transformed, failed, or duplicated?**

``` sql
WITH params AS (
    SELECT
        date_trunc('week', CURRENT_DATE)::date - 7 AS start_date,
        date_trunc('week', CURRENT_DATE)::date - 1 AS end_date
),
latest_batch_run AS (
    SELECT *
    FROM (
        SELECT
            r.*,
            ROW_NUMBER() OVER (
                PARTITION BY r.batch_id, r.rpt_grp_id
                ORDER BY r.seq_no DESC, r.modified_timestamp DESC
            ) rn
        FROM report_transformation_reconciliation r
        CROSS JOIN params p
        WHERE r.created_timestamp >= p.start_date
          AND r.created_timestamp < p.end_date + INTERVAL '1 day'
    ) x
    WHERE rn = 1
)
SELECT
    SUM(COALESCE(txn_selected, 0)) AS selected_for_processing,
    SUM(COALESCE(excluded_txn, 0)) AS excluded_txn,
    SUM(COALESCE(already_reported_count, 0)) AS already_reported,
    SUM(COALESCE(excluded_txn, 0) + COALESCE(already_reported_count, 0))
        AS filtered_not_eligible,
    SUM(COALESCE(txn_missing_attempt_count, 0)) AS txn_missing_attempt_count,
    SUM(COALESCE(expected_reportable_txn, 0)) AS expected_reportable,
    SUM(COALESCE(actual_reportable_txn, 0)) AS actual_reportable,
    SUM(COALESCE(activity_transformed, 0)) AS transformed,
    SUM(COALESCE(activity_transformation_failed, 0)) AS transformation_failed,
    SUM(COALESCE(duplicate_transformation, 0)) AS duplicate_transformation,
    SUM(COALESCE(soft_dedup_dropped_txn_count, 0)) AS soft_dedup_dropped
FROM latest_batch_run;
```

### ⚠ VALIDATE

`txn_missing_attempt_count` produced a very large value in the sample
results. Do **not** label it "Join Errors" or add it directly to
`activity_transformation_failed` until its exact grain/business
definition is confirmed.

------------------------------------------------------------------------

# 5. Reportable Reconciliation

## 5.1 Expected vs Actual Reportable Transactions

### Question answered

**Did every transaction expected to be reportable actually become
reportable?**

``` sql
WITH latest_batch_run AS (
    SELECT *
    FROM (
        SELECT
            r.*,
            ROW_NUMBER() OVER (
                PARTITION BY r.batch_id, r.rpt_grp_id
                ORDER BY r.seq_no DESC, r.modified_timestamp DESC
            ) rn
        FROM report_transformation_reconciliation r
        WHERE r.created_timestamp >= :start_date
          AND r.created_timestamp < :end_date + INTERVAL '1 day'
    ) x
    WHERE rn = 1
)
SELECT
    SUM(COALESCE(expected_reportable_txn, 0)) AS expected_reportable,
    SUM(COALESCE(actual_reportable_txn, 0)) AS actual_reportable,
    SUM(
        COALESCE(expected_reportable_txn, 0)
        - COALESCE(actual_reportable_txn, 0)
    ) AS reportable_difference
FROM latest_batch_run;
```

A non-zero difference should be clickable.

------------------------------------------------------------------------

# 6. Activity Eligibility Reconciliation

## 6.1 Expected vs Actual Eligible for Transformation

### Question answered

**Did the system identify the same number of transformation-eligible
activities that reconciliation expected?**

``` sql
WITH latest_batch_run AS (
    SELECT *
    FROM (
        SELECT
            r.*,
            ROW_NUMBER() OVER (
                PARTITION BY r.batch_id, r.rpt_grp_id
                ORDER BY r.seq_no DESC, r.modified_timestamp DESC
            ) rn
        FROM report_transformation_reconciliation r
        WHERE r.created_timestamp >= :start_date
          AND r.created_timestamp < :end_date + INTERVAL '1 day'
    ) x
    WHERE rn = 1
)
SELECT
    SUM(COALESCE(expected_activity_eligible_for_transformation, 0))
        AS expected_eligible,
    SUM(COALESCE(actual_activity_eligible_for_transformation, 0))
        AS actual_eligible,
    SUM(
        COALESCE(expected_activity_eligible_for_transformation, 0)
        - COALESCE(actual_activity_eligible_for_transformation, 0)
    ) AS eligibility_difference
FROM latest_batch_run;
```

------------------------------------------------------------------------

# 7. Reconciliation Issues KPI

## 7.1 Runs Out of Balance

### Question answered

**How many batch/report-group runs have a reconciliation discrepancy?**

Also answers:

-   How many report groups are affected?
-   How many batches are affected?

``` sql
WITH latest_batch_run AS (
    SELECT *
    FROM (
        SELECT
            r.*,
            ROW_NUMBER() OVER (
                PARTITION BY r.batch_id, r.rpt_grp_id
                ORDER BY r.seq_no DESC, r.modified_timestamp DESC
            ) rn
        FROM report_transformation_reconciliation r
        WHERE r.created_timestamp >= :start_date
          AND r.created_timestamp < :end_date + INTERVAL '1 day'
    ) x
    WHERE rn = 1
),
recon AS (
    SELECT
        batch_id,
        rpt_grp_id,
        rpt_grp_name,

        COALESCE(expected_reportable_txn,0)
          - COALESCE(actual_reportable_txn,0)
            AS reportable_diff,

        COALESCE(expected_activity_eligible_for_transformation,0)
          - COALESCE(actual_activity_eligible_for_transformation,0)
            AS activity_eligibility_diff,

        COALESCE(actual_activity_eligible_for_transformation,0)
          - (
              COALESCE(activity_transformed,0)
            + COALESCE(activity_transformation_failed,0)
            + COALESCE(duplicate_transformation,0)
            )
            AS transformation_disposition_diff

    FROM latest_batch_run
)
SELECT
    COUNT(*) FILTER (
        WHERE reportable_diff <> 0
           OR activity_eligibility_diff <> 0
           OR transformation_disposition_diff <> 0
    ) AS reconciliation_issues,

    COUNT(DISTINCT rpt_grp_id) FILTER (
        WHERE reportable_diff <> 0
           OR activity_eligibility_diff <> 0
           OR transformation_disposition_diff <> 0
    ) AS affected_report_groups,

    COUNT(DISTINCT batch_id) FILTER (
        WHERE reportable_diff <> 0
           OR activity_eligibility_diff <> 0
           OR transformation_disposition_diff <> 0
    ) AS affected_batches

FROM recon;
```

### ⚠ VALIDATE

The transformation-disposition equation assumes:

`actual eligible = transformed + failed + duplicate`

Confirm that those categories are mutually exclusive and exhaustive
before production use.

------------------------------------------------------------------------

# 8. Reconciliation Issue Detail

## 8.1 Which Runs Are Out of Balance?

### Question answered

**Exactly which report group and batch is out of balance, and which
control failed?**

``` sql
WITH latest_batch_run AS (
    SELECT *
    FROM (
        SELECT
            r.*,
            ROW_NUMBER() OVER (
                PARTITION BY r.batch_id, r.rpt_grp_id
                ORDER BY r.seq_no DESC, r.modified_timestamp DESC
            ) rn
        FROM report_transformation_reconciliation r
        WHERE r.created_timestamp >= :start_date
          AND r.created_timestamp < :end_date + INTERVAL '1 day'
    ) x
    WHERE rn = 1
)
SELECT
    batch_id,
    rpt_grp_id,
    rpt_grp_name,

    expected_reportable_txn,
    actual_reportable_txn,
    COALESCE(expected_reportable_txn,0)
      - COALESCE(actual_reportable_txn,0) AS reportable_diff,

    expected_activity_eligible_for_transformation,
    actual_activity_eligible_for_transformation,
    COALESCE(expected_activity_eligible_for_transformation,0)
      - COALESCE(actual_activity_eligible_for_transformation,0)
      AS activity_eligibility_diff,

    activity_transformed,
    activity_transformation_failed,
    duplicate_transformation,

    COALESCE(actual_activity_eligible_for_transformation,0)
      - (
          COALESCE(activity_transformed,0)
        + COALESCE(activity_transformation_failed,0)
        + COALESCE(duplicate_transformation,0)
      ) AS transformation_disposition_diff,

    created_timestamp,
    modified_timestamp

FROM latest_batch_run
WHERE
       COALESCE(expected_reportable_txn,0)
         <> COALESCE(actual_reportable_txn,0)

    OR COALESCE(expected_activity_eligible_for_transformation,0)
         <> COALESCE(actual_activity_eligible_for_transformation,0)

    OR COALESCE(actual_activity_eligible_for_transformation,0)
         <> (
              COALESCE(activity_transformed,0)
            + COALESCE(activity_transformation_failed,0)
            + COALESCE(duplicate_transformation,0)
         )
ORDER BY rpt_grp_name, batch_id;
```

------------------------------------------------------------------------

# 9. Batch Health

## 9.1 Batch Health Table

### Question answered

**Which batches need Operations attention, and why?**

``` sql
WITH latest_batch_run AS (
    SELECT *
    FROM (
        SELECT
            r.*,
            ROW_NUMBER() OVER (
                PARTITION BY r.batch_id, r.rpt_grp_id
                ORDER BY r.seq_no DESC, r.modified_timestamp DESC
            ) rn
        FROM report_transformation_reconciliation r
        WHERE r.created_timestamp >= :start_date
          AND r.created_timestamp < :end_date + INTERVAL '1 day'
    ) x
    WHERE rn = 1
)
SELECT
    batch_id,
    rpt_grp_id,
    rpt_grp_name,
    seq_no,

    txn_selected,
    expected_reportable_txn,
    actual_reportable_txn,

    expected_activity_eligible_for_transformation,
    actual_activity_eligible_for_transformation,

    activity_transformed,
    activity_transformation_failed,
    duplicate_transformation,
    txn_missing_attempt_count,

    COALESCE(expected_reportable_txn,0)
      - COALESCE(actual_reportable_txn,0) AS reportable_diff,

    COALESCE(expected_activity_eligible_for_transformation,0)
      - COALESCE(actual_activity_eligible_for_transformation,0)
      AS eligibility_diff,

    CASE
        WHEN
             COALESCE(expected_reportable_txn,0)
                <> COALESCE(actual_reportable_txn,0)
          OR COALESCE(expected_activity_eligible_for_transformation,0)
                <> COALESCE(actual_activity_eligible_for_transformation,0)
        THEN 'NEEDS ATTENTION'

        WHEN COALESCE(activity_transformation_failed,0) > 0
        THEN 'WARNING'

        ELSE 'HEALTHY'
    END AS batch_status,

    modified_timestamp AS last_updated

FROM latest_batch_run
ORDER BY
    CASE
        WHEN
             COALESCE(expected_reportable_txn,0)
                <> COALESCE(actual_reportable_txn,0)
          OR COALESCE(expected_activity_eligible_for_transformation,0)
                <> COALESCE(actual_activity_eligible_for_transformation,0)
        THEN 1
        WHEN COALESCE(activity_transformation_failed,0) > 0 THEN 2
        ELSE 3
    END,
    modified_timestamp DESC;
```

------------------------------------------------------------------------

# 10. Batch Detail

## 10.1 Full Reconciliation Detail for One Batch

### Question answered

**What happened in this particular batch?**

``` sql
SELECT
    batch_id,
    seq_no,
    rpt_grp_id,
    rpt_grp_name,
    rpt_look_back_date,
    rpt_from_date,
    rpt_to_date,

    txn_selected,
    txn_simulated,
    excluded_txn,
    txn_missing_attempt_count,
    already_reported_count,

    expected_reportable_txn,
    actual_reportable_txn,

    lookback_txn,
    lookback_future_reporting_txn,
    lookback_actual_txn,

    reporting_period_txn,
    reporting_period_future_reporting_txn,
    reporting_period_actual_txn,

    activity_selected,
    activity_missing,
    activity_simulated,

    expected_activity_eligible_for_transformation,
    actual_activity_eligible_for_transformation,

    activity_transformed,
    activity_transformation_failed,
    duplicate_transformation,

    created_timestamp,
    modified_timestamp,
    soft_dedup_dropped_txn_count

FROM report_transformation_reconciliation
WHERE batch_id = :batch_id
ORDER BY seq_no DESC, modified_timestamp DESC;
```

This view intentionally exposes the raw reconciliation fields instead of
hiding them behind a single status.

------------------------------------------------------------------------

# 11. Transformation Failures

## 11.1 Failure Count by Report Group / Batch

### Question answered

**Where are transformation failures occurring?**

``` sql
WITH latest_batch_run AS (
    SELECT *
    FROM (
        SELECT
            r.*,
            ROW_NUMBER() OVER (
                PARTITION BY r.batch_id, r.rpt_grp_id
                ORDER BY r.seq_no DESC, r.modified_timestamp DESC
            ) rn
        FROM report_transformation_reconciliation r
        WHERE r.created_timestamp >= :start_date
          AND r.created_timestamp < :end_date + INTERVAL '1 day'
    ) x
    WHERE rn = 1
)
SELECT
    rpt_grp_id,
    rpt_grp_name,
    batch_id,
    activity_transformation_failed AS failed_count,
    modified_timestamp
FROM latest_batch_run
WHERE COALESCE(activity_transformation_failed,0) > 0
ORDER BY activity_transformation_failed DESC;
```

------------------------------------------------------------------------

## 11.2 Failed Transaction Detail

### Question answered

**Which individual records failed transformation, and what
reason/comment was captured?**

``` sql
SELECT
    rpt_grp_id,
    batch_id,
    identifier,
    mtcn,
    stage,
    status,
    comments,
    skip_reason,
    created_timestamp,
    modified_timestamp,
    reporting_timestamp_latest
FROM record_transformation_journey
WHERE batch_id = :batch_id
  AND rpt_grp_id = :rpt_grp_id
  AND (
        UPPER(status) = 'FAILURE'
        OR UPPER(status) = 'FAILED'
      )
ORDER BY modified_timestamp DESC;
```

> Adjust the exact status literal after confirming the values present in
> `record_transformation_journey`.

------------------------------------------------------------------------

# 12. Missing Attempt / Transaction Join Investigation

## 12.1 Journey Records for Join Problems

### Question answered

**Which transactions failed or stopped during `TRANSACTION_JOIN`, and
why?**

``` sql
SELECT
    rpt_grp_id,
    batch_id,
    identifier,
    mtcn,
    stage,
    status,
    comments,
    skip_reason,
    created_timestamp,
    modified_timestamp,
    txn_metadata
FROM record_transformation_journey
WHERE batch_id = :batch_id
  AND rpt_grp_id = :rpt_grp_id
  AND UPPER(stage) = 'TRANSACTION_JOIN'
  AND (
       UPPER(status) IN ('ERROR', 'FAILURE', 'FAILED')
       OR skip_reason IS NOT NULL
  )
ORDER BY modified_timestamp DESC;
```

### ⚠ VALIDATE

Use the journey table to establish the actual transaction-level
join-error population. Do not assume `txn_missing_attempt_count` alone
is a transaction count until its semantics are confirmed.

------------------------------------------------------------------------

# 13. Transaction Journey

## 13.1 End-to-End Journey for a Transaction

### Question answered

**What happened to this specific transaction from filtration through
transformation?**

``` sql
SELECT
    rpt_grp_id,
    batch_id,
    identifier,
    mtcn,
    stage,
    status,
    comments,
    skip_reason,
    processing_complete,
    txn_metadata,
    created_timestamp,
    modified_timestamp,
    reporting_timestamp_latest
FROM record_transformation_journey
WHERE identifier = :identifier
   OR mtcn = :mtcn
ORDER BY created_timestamp, modified_timestamp;
```

This is the final investigation layer:

`Dashboard → Report Group → Batch → Transaction Journey`

------------------------------------------------------------------------

# 14. Rule-Hit Exclusions

## 14.1 Exclusion Reasons from `rule_hit`

### Question answered

**For rule hits in the selected transaction-date cohort, why were they
excluded?**

``` sql
WITH params AS (
    SELECT
        date_trunc('week', CURRENT_DATE)::date - 7 AS start_date,
        date_trunc('week', CURRENT_DATE)::date - 1 AS end_date
)
SELECT
    exclusion_reason_id,
    COUNT(*) AS excluded_hits,
    ROUND(
        100.0 * COUNT(*)
        / NULLIF(SUM(COUNT(*)) OVER (), 0),
        2
    ) AS pct_of_excluded
FROM rule_hit rh
CROSS JOIN params p
WHERE rh.transaction_date >= p.start_date
  AND rh.transaction_date < p.end_date + INTERVAL '1 day'
  AND exclusion_reason_id IS NOT NULL
GROUP BY exclusion_reason_id
ORDER BY excluded_hits DESC;
```

------------------------------------------------------------------------

# 15. Exclusion Audit

## 15.1 Exclusion Audit by Reason and Strategy

### Question answered

**What exclusion decisions were written to the exclusion audit during
the selected period, and which strategy generated them?**

``` sql
WITH params AS (
    SELECT
        date_trunc('week', CURRENT_DATE)::date - 7 AS start_date,
        date_trunc('week', CURRENT_DATE)::date - 1 AS end_date
)
SELECT
    exclusion_reason_id,
    exclusion_strategy,
    COUNT(*) AS excluded_count
FROM rule_hit_exclusion_audit a
CROSS JOIN params p
WHERE a.created_timestamp >= p.start_date
  AND a.created_timestamp < p.end_date + INTERVAL '1 day'
GROUP BY exclusion_reason_id, exclusion_strategy
ORDER BY excluded_count DESC;
```

### Important

Do **not** directly reconcile this count to the `rule_hit` exclusion
count unless the relationship and time semantics are confirmed.

`rule_hit` is being filtered by `transaction_date`.

`rule_hit_exclusion_audit` is being filtered by `created_timestamp`.

They answer different questions.

------------------------------------------------------------------------

# 16. Rule-Hit Data Quality / `is_reported`

## 16.1 `is_reported` Distribution

### Question answered

**How populated and reliable is the `is_reported` flag?**

``` sql
SELECT
    is_reported,
    COUNT(*) AS hit_count
FROM rule_hit
GROUP BY is_reported
ORDER BY is_reported;
```

The observed data contained substantial `NULL` values. Therefore this
field should **not** be the sole basis of the top-level
reporting-success KPI.

------------------------------------------------------------------------

## 16.2 `is_reported` vs Exclusion State

### Question answered

**How does `is_reported` relate to excluded/non-excluded records?**

``` sql
SELECT
    is_reported,
    CASE
        WHEN exclusion_reason_id IS NULL THEN 'NO_EXCLUSION'
        ELSE 'EXCLUDED'
    END AS exclusion_status,
    COUNT(*) AS total_rows,

    COUNT(*) FILTER (
        WHERE reporting_timestamp IS NULL
    ) AS reporting_timestamp_null,

    COUNT(*) FILTER (
        WHERE reporting_timestamp IS NOT NULL
    ) AS reporting_timestamp_present,

    COUNT(*) FILTER (
        WHERE reported_batch_id IS NULL
    ) AS reported_batch_null,

    COUNT(*) FILTER (
        WHERE reported_batch_id IS NOT NULL
    ) AS reported_batch_present

FROM rule_hit
GROUP BY
    is_reported,
    CASE
        WHEN exclusion_reason_id IS NULL THEN 'NO_EXCLUSION'
        ELSE 'EXCLUDED'
    END
ORDER BY is_reported, exclusion_status;
```

This is primarily a **data-quality/semantic validation query**, not a
dashboard KPI.

------------------------------------------------------------------------

# 17. Optional Rule-Hit Cohort Check

## 17.1 Transaction-Date Cohort Balance

### Question answered

**Within the selected `rule_hit.transaction_date` cohort, do excluded +
reportable equal total, and do reported + open equal reportable?**

``` sql
WITH params AS (
    SELECT
        date_trunc('week', CURRENT_DATE)::date - 7 AS start_date,
        date_trunc('week', CURRENT_DATE)::date - 1 AS end_date
),
m AS (
    SELECT
        COUNT(*) AS total_hits,

        COUNT(*) FILTER (
            WHERE exclusion_reason_id IS NOT NULL
        ) AS excluded,

        COUNT(*) FILTER (
            WHERE exclusion_reason_id IS NULL
        ) AS requires_reporting,

        COUNT(*) FILTER (
            WHERE exclusion_reason_id IS NULL
              AND reporting_timestamp IS NOT NULL
              AND reporting_timestamp < p.end_date + INTERVAL '1 day'
        ) AS reported,

        COUNT(*) FILTER (
            WHERE exclusion_reason_id IS NULL
              AND (
                    reporting_timestamp IS NULL
                    OR reporting_timestamp >= p.end_date + INTERVAL '1 day'
                  )
        ) AS open

    FROM rule_hit rh
    CROSS JOIN params p
    WHERE rh.transaction_date >= p.start_date
      AND rh.transaction_date < p.end_date + INTERVAL '1 day'
)
SELECT
    *,
    total_hits - (excluded + requires_reporting) AS rule_hit_balance_diff,
    requires_reporting - (reported + open) AS reporting_balance_diff
FROM m;
```

### Use

This is a **cohort integrity check**, not necessarily the enterprise
reporting-health KPI.

The sample last-week result showed a very small rule-hit cohort, so the
reconciliation tables are more appropriate for the main Operations
dashboard.

------------------------------------------------------------------------

# 18. Dashboard-to-Query Mapping

  ----------------------------------------------------------------------------------------
  Dashboard Component     Primary Source                           Question
  ----------------------- ---------------------------------------- -----------------------
  Expected Rule Hits      `rule_hit_reconciliation`                How many rule hits
                                                                   should Pharos have
                                                                   received?

  Matched Rule Hits       `rule_hit_reconciliation`                How many expected hits
                                                                   matched Pharos?

  Missed Rule Hits        `rule_hit_reconciliation`                How many expected hits
                                                                   are missing?

  Match Rate              `rule_hit_reconciliation`                What percentage
                                                                   reconciled
                                                                   successfully?

  Reporting Trend         `rule_hit_reconciliation`                When did reporting
                                                                   mismatch occur?

  Report Group Health     `rule_hit_reconciliation`                Which report groups
                                                                   caused misses?

  Reconciliation Issues   `report_transformation_reconciliation`   Which
                                                                   batch/report-group
                                                                   controls are out of
                                                                   balance?

  Affected Report Groups  `report_transformation_reconciliation`   How widespread are
                                                                   reconciliation issues?

  Affected Batches        `report_transformation_reconciliation`   Which batches require
                                                                   investigation?

  Expected vs Actual      `report_transformation_reconciliation`   Did reportable
  Reportable                                                       transaction counts
                                                                   reconcile?

  Expected vs Actual      `report_transformation_reconciliation`   Did transformation
  Eligible                                                         eligibility reconcile?

  Transformation Failed   `report_transformation_reconciliation`   How many failures were
                                                                   recorded?

  Batch Health            `report_transformation_reconciliation`   Which batches need
                                                                   attention?

  Batch Detail            `report_transformation_reconciliation`   What happened in a
                                                                   specific batch?

  Failure Detail          `record_transformation_journey`          Which transactions
                                                                   failed and why?

  Join Investigation      `record_transformation_journey`          Which records
                                                                   failed/stopped at
                                                                   transaction join?

  Transaction Journey     `record_transformation_journey`          What happened
                                                                   end-to-end to one
                                                                   transaction?

  Rule-Hit Exclusions     `rule_hit`                               Why were rule hits in
                                                                   the transaction cohort
                                                                   excluded?

  Exclusion Audit         `rule_hit_exclusion_audit`               What exclusion
                                                                   decisions were audited
                                                                   and by what strategy?
  ----------------------------------------------------------------------------------------

------------------------------------------------------------------------

# 19. Recommended Drill-Down Navigation

``` text
OVERVIEW
│
├── Missed Rule Hits
│      └── Report Group
│             └── Run
│                    └── underlying transaction/rule-hit investigation
│
├── Report Group Health
│      └── Report Group Detail
│             ├── Reporting Reconciliation
│             ├── Batches
│             ├── Transformation
│             └── Exceptions
│
├── Reconciliation Issues
│      └── Report Group + Batch
│             └── Batch Detail
│                    └── Transaction Journey
│
├── Batch Health
│      └── Batch Detail
│             ├── Reportable Control
│             ├── Eligibility Control
│             ├── Transformation Outcomes
│             └── Journey Records
│
├── Transformation Failures
│      └── Failed Transactions
│             └── Transaction Journey
│
└── Exclusions
       ├── Rule-Hit Exclusions
       └── Exclusion Audit
```

------------------------------------------------------------------------

# 20. Production Rules

1.  **Deduplicate reconciliation snapshots before aggregating.**\
    Use latest `seq_no`/`modified_timestamp` at the correct business
    grain.

2.  **Never mix time anchors silently.**\
    `transaction_date`, `run_date`, `created_timestamp`,
    `modified_timestamp`, and `reporting_timestamp` represent different
    concepts.

3.  **Keep report-group and batch filters throughout drill-down.**

4.  **Do not use `rule_hit.is_reported` as the primary reporting KPI**
    until its NULL semantics are established.

5.  **Do not call `txn_missing_attempt_count` "Join Errors" yet.**\
    Validate its grain and business definition first.

6.  **Do not add unrelated exception counters together** merely to
    create a "Processing Exceptions" KPI.

7.  **Keep expected-vs-actual controls visible.**\
    Operations needs to see both sides of a reconciliation, not only the
    difference.

8.  **Every red KPI must be drillable.**\
    A user should be able to move from:

    `KPI → report group → batch/run → transaction → reason`.

9.  **Display the source/grain in tooltips.**\
    Example:
    `Source: rule_hit_reconciliation; latest record per report group + run date`.

10. **Validate transformation-disposition semantics before enforcing
    balance.**\
    Confirm whether transformed, failed, duplicate, and any other
    outcomes are mutually exclusive and exhaustive.
