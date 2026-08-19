# IFTI Compliance Operations Dashboard — SQL Query Catalog

## Purpose

This document contains the SQL query set for the approved **period-based compliance operations dashboard** and its drill-down investigation flow.

The dashboard is designed to answer, for any selected period:

- How many batches ran?
- How many report groups ran?
- How many batches had issues?
- What types of issues occurred?
- How many rule hits were expected, matched, and missed?
- Which report groups caused the problems?
- Which batches need investigation?
- What failed during transformation?
- Which specific transactions were affected?
- Why did a transaction fail, get skipped, or get excluded?
- What is the full journey for a transaction?

The core tables used are:

- `rule_hit`
- `rule_hit_reconciliation`
- `rule_hit_exclusion_audit`
- `record_transformation_journey`
- `report_transformation_reconciliation`

---

# 1. Common Dashboard Parameters

All dashboard queries should use the same filter inputs.

```sql
WITH params AS (
    SELECT
        :start_date::date AS start_date,
        :end_date::date   AS end_date,
        :rpt_grp_id::bigint AS rpt_grp_id,
        :batch_id::text      AS batch_id,
        :rule_id::text       AS rule_id
)
```

## Example: Previous Calendar Month

```sql
SELECT
    date_trunc('month', CURRENT_DATE - INTERVAL '1 month')::date
        AS start_date,

    (date_trunc('month', CURRENT_DATE)::date - 1)
        AS end_date;
```

---

# 2. Base Transformation Dataset — Latest Batch State

## Question Answered

**For every batch/report group in the selected period, what is its latest reconciliation state?**

This is the base CTE for most batch-level dashboard metrics.

```sql
WITH latest_batch_run AS (
    SELECT *
    FROM (
        SELECT
            r.*,

            ROW_NUMBER() OVER (
                PARTITION BY r.batch_id, r.rpt_grp_id
                ORDER BY
                    r.seq_no DESC,
                    r.modified_timestamp DESC
            ) AS rn

        FROM report_transformation_reconciliation r

        WHERE r.created_timestamp >= :start_date
          AND r.created_timestamp < :end_date + INTERVAL '1 day'

          AND (
                :rpt_grp_id IS NULL
                OR r.rpt_grp_id = :rpt_grp_id
              )

          AND (
                :batch_id IS NULL
                OR r.batch_id = :batch_id
              )
    ) x
    WHERE rn = 1
)

SELECT *
FROM latest_batch_run;
```

### Why this matters

The same batch/report group can have multiple reconciliation rows because of reprocessing or new `seq_no` values. The dashboard should normally aggregate only the latest state.

---

# 3. Main Dashboard KPI Cards

## Questions Answered

- How many batches ran?
- How many report groups ran?
- How many batches need investigation?
- How many transformation failures occurred?
- How many batches have reconciliation issues?

```sql
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

batch_eval AS (
    SELECT
        *,

        COALESCE(expected_reportable_txn, 0)
          - COALESCE(actual_reportable_txn, 0)
            AS reportable_diff,

        COALESCE(expected_activity_eligible_for_transformation, 0)
          - COALESCE(actual_activity_eligible_for_transformation, 0)
            AS eligibility_diff

    FROM latest_batch_run
)

SELECT
    COUNT(DISTINCT batch_id)
        AS batches_run,

    COUNT(DISTINCT rpt_grp_id)
        AS report_groups_run,

    COUNT(DISTINCT batch_id) FILTER (
        WHERE reportable_diff <> 0
           OR eligibility_diff <> 0
           OR COALESCE(activity_transformation_failed,0) > 0
    ) AS batches_with_issues,

    SUM(COALESCE(activity_transformation_failed,0))
        AS transformation_failures,

    COUNT(DISTINCT batch_id) FILTER (
        WHERE reportable_diff <> 0
           OR eligibility_diff <> 0
    ) AS reconciliation_issue_batches

FROM batch_eval;
```

### Important

Do **not** define a bad batch simply as:

```sql
txn_missing_attempt_count > 0
```

The observed data indicates that field is not behaving like a simple transaction-level error counter.

---

# 4. Rule Hit Reconciliation for the Selected Period

## Question Answered

**During the selected period, how many rule hits were expected, matched, and missed?**

```sql
WITH latest_rule_recon AS (
    SELECT *
    FROM (
        SELECT
            r.*,

            ROW_NUMBER() OVER (
                PARTITION BY
                    r.rpt_grp_id,
                    r.run_date
                ORDER BY
                    r.seq_no DESC,
                    r.modified_timestamp DESC
            ) rn

        FROM rule_hit_reconciliation r

        WHERE r.run_date >= TO_CHAR(:start_date, 'YYYYMMDD')::INTEGER
          AND r.run_date <= TO_CHAR(:end_date, 'YYYYMMDD')::INTEGER

          AND (
                :rpt_grp_id IS NULL
                OR r.rpt_grp_id = :rpt_grp_id
              )

    ) x
    WHERE rn = 1
)

SELECT
    SUM(COALESCE(distinct_rule_hits_count_iwra,0))
        AS expected_rule_hits,

    SUM(COALESCE(distinct_rule_hits_count_pharos,0))
        AS matched_rule_hits,

    SUM(COALESCE(missed_rule_hits_count_pharos,0))
        AS missed_rule_hits,

    ROUND(
        100.0
        * SUM(COALESCE(distinct_rule_hits_count_pharos,0))
        / NULLIF(
            SUM(COALESCE(distinct_rule_hits_count_iwra,0)),
            0
        ),
        2
    ) AS match_rate_pct

FROM latest_rule_recon;
```

### Dashboard Metrics

- Expected Rule Hits
- Matched Rule Hits
- Missed Rule Hits
- Match Rate %

---

# 5. Combined Main Dashboard Summary

## Question Answered

**Can the API return all main dashboard KPI values in one response?**

```sql
WITH
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
        WHERE r.created_timestamp >= :start_date
          AND r.created_timestamp < :end_date + INTERVAL '1 day'
    ) x
    WHERE rn = 1
),

batch_summary AS (
    SELECT
        COUNT(DISTINCT batch_id) AS batches_run,
        COUNT(DISTINCT rpt_grp_id) AS report_groups_run,

        COUNT(DISTINCT batch_id) FILTER (
            WHERE
                COALESCE(expected_reportable_txn,0)
                    <> COALESCE(actual_reportable_txn,0)

                OR COALESCE(expected_activity_eligible_for_transformation,0)
                    <> COALESCE(actual_activity_eligible_for_transformation,0)

                OR COALESCE(activity_transformation_failed,0) > 0
        ) AS batches_with_issues,

        SUM(COALESCE(activity_transformation_failed,0))
            AS transformation_failures,

        COUNT(DISTINCT batch_id) FILTER (
            WHERE
                COALESCE(expected_reportable_txn,0)
                    <> COALESCE(actual_reportable_txn,0)

                OR COALESCE(expected_activity_eligible_for_transformation,0)
                    <> COALESCE(actual_activity_eligible_for_transformation,0)
        ) AS reconciliation_issue_batches

    FROM latest_batch_run
),

latest_rule_recon AS (
    SELECT *
    FROM (
        SELECT
            r.*,
            ROW_NUMBER() OVER (
                PARTITION BY r.rpt_grp_id, r.run_date
                ORDER BY r.seq_no DESC, r.modified_timestamp DESC
            ) rn

        FROM rule_hit_reconciliation r

        WHERE r.run_date >= TO_CHAR(:start_date, 'YYYYMMDD')::INTEGER
          AND r.run_date <= TO_CHAR(:end_date, 'YYYYMMDD')::INTEGER
    ) x

    WHERE rn = 1
),

rule_summary AS (
    SELECT
        SUM(COALESCE(distinct_rule_hits_count_iwra,0))
            AS expected_rule_hits,

        SUM(COALESCE(distinct_rule_hits_count_pharos,0))
            AS matched_rule_hits,

        SUM(COALESCE(missed_rule_hits_count_pharos,0))
            AS missed_rule_hits

    FROM latest_rule_recon
)

SELECT
    bs.batches_run,
    bs.report_groups_run,
    bs.batches_with_issues,
    rs.expected_rule_hits,
    rs.matched_rule_hits,
    rs.missed_rule_hits,
    bs.transformation_failures,
    bs.reconciliation_issue_batches

FROM batch_summary bs
CROSS JOIN rule_summary rs;
```

---

# 6. Batch Health Breakdown

## Question Answered

**How many batches were healthy, need attention, or are critical?**

```sql
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

classified AS (
    SELECT
        *,

        CASE
            WHEN
                COALESCE(expected_reportable_txn,0)
                  <> COALESCE(actual_reportable_txn,0)
                OR
                COALESCE(expected_activity_eligible_for_transformation,0)
                  <> COALESCE(actual_activity_eligible_for_transformation,0)

            THEN 'CRITICAL'

            WHEN COALESCE(activity_transformation_failed,0) > 0
            THEN 'NEEDS_ATTENTION'

            ELSE 'HEALTHY'
        END AS health_status

    FROM latest_batch_run
)

SELECT
    health_status,
    COUNT(DISTINCT batch_id) AS batch_count
FROM classified
GROUP BY health_status
ORDER BY
    CASE health_status
        WHEN 'CRITICAL' THEN 1
        WHEN 'NEEDS_ATTENTION' THEN 2
        ELSE 3
    END;
```

---

# 7. Issues by Type

## Question Answered

**What kinds of issues occurred during the selected period?**

```sql
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
    'REPORTABLE_RECON_DIFF' AS issue_type,
    COUNT(DISTINCT batch_id) AS affected_batches
FROM latest_batch_run
WHERE COALESCE(expected_reportable_txn,0)
   <> COALESCE(actual_reportable_txn,0)

UNION ALL

SELECT
    'ELIGIBILITY_RECON_DIFF',
    COUNT(DISTINCT batch_id)
FROM latest_batch_run
WHERE COALESCE(expected_activity_eligible_for_transformation,0)
   <> COALESCE(actual_activity_eligible_for_transformation,0)

UNION ALL

SELECT
    'TRANSFORMATION_FAILURE',
    COUNT(DISTINCT batch_id)
FROM latest_batch_run
WHERE COALESCE(activity_transformation_failed,0) > 0

UNION ALL

SELECT
    'DUPLICATE_TRANSFORMATION',
    COUNT(DISTINCT batch_id)
FROM latest_batch_run
WHERE COALESCE(duplicate_transformation,0) > 0

ORDER BY affected_batches DESC;
```

### Important

One batch can have multiple issue types. Therefore the issue-type counts do not have to sum to total problem batches.

---

# 8. Report Group Health

## Question Answered

**Which report groups ran, how many batches did each run, and which report groups caused the most issues?**

```sql
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

batch_rg AS (
    SELECT
        rpt_grp_id,
        rpt_grp_name,

        COUNT(DISTINCT batch_id) AS batches_run,

        COUNT(DISTINCT batch_id) FILTER (
            WHERE
                COALESCE(expected_reportable_txn,0)
                   <> COALESCE(actual_reportable_txn,0)
             OR COALESCE(expected_activity_eligible_for_transformation,0)
                   <> COALESCE(actual_activity_eligible_for_transformation,0)
             OR COALESCE(activity_transformation_failed,0) > 0
        ) AS issue_batches,

        SUM(COALESCE(activity_transformation_failed,0))
            AS transformation_failures,

        MAX(created_timestamp) AS latest_batch_timestamp

    FROM latest_batch_run
    GROUP BY rpt_grp_id, rpt_grp_name
),

latest_rule_recon AS (
    SELECT *
    FROM (
        SELECT
            r.*,
            ROW_NUMBER() OVER (
                PARTITION BY r.rpt_grp_id, r.run_date
                ORDER BY r.seq_no DESC, r.modified_timestamp DESC
            ) rn

        FROM rule_hit_reconciliation r

        WHERE r.run_date >= TO_CHAR(:start_date,'YYYYMMDD')::INTEGER
          AND r.run_date <= TO_CHAR(:end_date,'YYYYMMDD')::INTEGER
    ) x
    WHERE rn = 1
),

rule_rg AS (
    SELECT
        rpt_grp_id,

        SUM(COALESCE(distinct_rule_hits_count_iwra,0))
            AS expected_rule_hits,

        SUM(COALESCE(distinct_rule_hits_count_pharos,0))
            AS matched_rule_hits,

        SUM(COALESCE(missed_rule_hits_count_pharos,0))
            AS missed_rule_hits

    FROM latest_rule_recon
    GROUP BY rpt_grp_id
)

SELECT
    b.rpt_grp_id,
    b.rpt_grp_name,
    b.batches_run,

    b.batches_run - b.issue_batches
        AS healthy_batches,

    b.issue_batches,

    COALESCE(r.expected_rule_hits,0)
        AS expected_rule_hits,

    COALESCE(r.matched_rule_hits,0)
        AS matched_rule_hits,

    COALESCE(r.missed_rule_hits,0)
        AS missed_rule_hits,

    b.transformation_failures,

    b.latest_batch_timestamp

FROM batch_rg b
LEFT JOIN rule_rg r
    ON r.rpt_grp_id = b.rpt_grp_id

ORDER BY
    b.issue_batches DESC,
    COALESCE(r.missed_rule_hits,0) DESC;
```

---

# 9. Top Problem Batches

## Question Answered

**Which batches should Operations investigate first?**

```sql
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
      - COALESCE(actual_reportable_txn,0)
        AS reportable_diff,

    expected_activity_eligible_for_transformation,
    actual_activity_eligible_for_transformation,

    COALESCE(expected_activity_eligible_for_transformation,0)
      - COALESCE(actual_activity_eligible_for_transformation,0)
        AS eligibility_diff,

    activity_transformation_failed,
    duplicate_transformation,

    modified_timestamp

FROM latest_batch_run

WHERE
       COALESCE(expected_reportable_txn,0)
          <> COALESCE(actual_reportable_txn,0)

    OR COALESCE(expected_activity_eligible_for_transformation,0)
          <> COALESCE(actual_activity_eligible_for_transformation,0)

    OR COALESCE(activity_transformation_failed,0) > 0

ORDER BY
    ABS(
        COALESCE(expected_reportable_txn,0)
          - COALESCE(actual_reportable_txn,0)
    ) DESC,

    COALESCE(activity_transformation_failed,0) DESC,

    modified_timestamp DESC;
```

---

# 10. Operations Trend

## Question Answered

**Are batch problems getting better or worse during the selected period?**

```sql
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
    created_timestamp::date AS day,

    COUNT(DISTINCT batch_id)
        AS batches_run,

    COUNT(DISTINCT batch_id) FILTER (
        WHERE
            COALESCE(expected_reportable_txn,0)
              <> COALESCE(actual_reportable_txn,0)

         OR COALESCE(expected_activity_eligible_for_transformation,0)
              <> COALESCE(actual_activity_eligible_for_transformation,0)

         OR COALESCE(activity_transformation_failed,0) > 0
    ) AS issue_batches,

    SUM(COALESCE(activity_transformation_failed,0))
        AS transformation_failures

FROM latest_batch_run
GROUP BY created_timestamp::date
ORDER BY day;
```

---

# 11. Report Group Detail — Batches

## Question Answered

**For a selected report group, what batches ran and which batches had issues?**

```sql
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

        WHERE r.rpt_grp_id = :rpt_grp_id

          AND r.created_timestamp >= :start_date
          AND r.created_timestamp < :end_date + INTERVAL '1 day'
    ) x

    WHERE rn = 1
)

SELECT
    batch_id,
    created_timestamp,
    seq_no,

    txn_selected,

    expected_reportable_txn,
    actual_reportable_txn,

    activity_transformed,
    activity_transformation_failed,

    expected_activity_eligible_for_transformation,
    actual_activity_eligible_for_transformation,

    duplicate_transformation,

    CASE
        WHEN
             COALESCE(expected_reportable_txn,0)
                <> COALESCE(actual_reportable_txn,0)

          OR COALESCE(expected_activity_eligible_for_transformation,0)
                <> COALESCE(actual_activity_eligible_for_transformation,0)

        THEN 'CRITICAL'

        WHEN COALESCE(activity_transformation_failed,0) > 0
        THEN 'NEEDS_ATTENTION'

        ELSE 'HEALTHY'
    END AS status

FROM latest_batch_run

ORDER BY created_timestamp DESC;
```

---

# 12. Particular Batch Control Summary

## Question Answered

**For one specific batch, what was selected, expected, actual, transformed, failed, or duplicated?**

```sql
WITH latest AS (
    SELECT *
    FROM (
        SELECT
            r.*,

            ROW_NUMBER() OVER (
                PARTITION BY r.batch_id, r.rpt_grp_id
                ORDER BY r.seq_no DESC, r.modified_timestamp DESC
            ) rn

        FROM report_transformation_reconciliation r

        WHERE r.batch_id = :batch_id
          AND r.rpt_grp_id = :rpt_grp_id
    ) x

    WHERE rn = 1
)

SELECT
    batch_id,
    rpt_grp_id,
    rpt_grp_name,
    seq_no,

    created_timestamp,
    modified_timestamp,

    txn_selected,

    excluded_txn,
    already_reported_count,

    expected_reportable_txn,
    actual_reportable_txn,

    expected_reportable_txn
      - actual_reportable_txn
        AS reportable_diff,

    expected_activity_eligible_for_transformation,
    actual_activity_eligible_for_transformation,

    expected_activity_eligible_for_transformation
      - actual_activity_eligible_for_transformation
        AS eligibility_diff,

    activity_transformed,
    activity_transformation_failed,
    duplicate_transformation,

    soft_dedup_dropped_txn_count

FROM latest;
```

---

# 13. Batch Stage × Status Breakdown

## Question Answered

**At which processing stage did unique transactions succeed, fail, or stop?**

```sql
WITH latest_stage AS (
    SELECT *
    FROM (
        SELECT
            j.*,

            ROW_NUMBER() OVER (
                PARTITION BY
                    j.batch_id,
                    j.identifier,
                    j.stage
                ORDER BY
                    j.modified_timestamp DESC,
                    j.created_timestamp DESC
            ) rn

        FROM record_transformation_journey j

        WHERE j.batch_id = :batch_id
    ) x

    WHERE rn = 1
)

SELECT
    stage,
    status,

    COUNT(DISTINCT identifier)
        AS transaction_count

FROM latest_stage

GROUP BY
    stage,
    status

ORDER BY
    stage,
    transaction_count DESC;
```

### Why this is preferred

Using raw `COUNT(*)` can over-count retries or multiple stage-state rows for the same transaction.

---

# 14. Failure / Skip Reason Breakdown

## Question Answered

**What are the primary root-cause categories for failed or skipped transactions in the batch?**

```sql
WITH latest_stage AS (
    SELECT *
    FROM (
        SELECT
            j.*,

            ROW_NUMBER() OVER (
                PARTITION BY
                    j.batch_id,
                    j.identifier,
                    j.stage
                ORDER BY
                    j.modified_timestamp DESC,
                    j.created_timestamp DESC
            ) rn

        FROM record_transformation_journey j

        WHERE j.batch_id = :batch_id
    ) x

    WHERE rn = 1
),

classified AS (
    SELECT
        *,

        CASE
            WHEN UPPER(stage) = 'TRANSACTION_JOIN'
             AND (
                    UPPER(COALESCE(status,'')) = 'ERROR'
                    OR COALESCE(skip_reason,'')
                        ILIKE '%not yet recorded%'
                 )
            THEN 'ATTEMPT_NOT_RECEIVED'

            WHEN UPPER(stage) = 'TRANSFORMATION'
             AND UPPER(COALESCE(status,'')) IN ('FAILURE','FAILED')
            THEN 'TRANSFORMATION_FAILURE'

            WHEN COALESCE(skip_reason,'') <> ''
            THEN 'OTHER_SKIP_REASON'

            ELSE 'OTHER_FAILURE'
        END AS reason_category

    FROM latest_stage

    WHERE UPPER(COALESCE(status,'')) <> 'SUCCESS'
       OR skip_reason IS NOT NULL
)

SELECT
    stage,
    reason_category,

    COUNT(DISTINCT identifier)
        AS affected_transactions

FROM classified

GROUP BY
    stage,
    reason_category

ORDER BY affected_transactions DESC;
```

### Why classification is needed

Raw `skip_reason` values may contain transaction-specific values such as Attempt IDs, which would fragment one business reason into many rows.

---

# 15. Transformation Failure Detail

## Question Answered

**Which exact transactions failed transformation in the selected batch?**

```sql
WITH latest_stage AS (
    SELECT *
    FROM (
        SELECT
            j.*,

            ROW_NUMBER() OVER (
                PARTITION BY
                    j.identifier,
                    j.stage
                ORDER BY
                    j.modified_timestamp DESC,
                    j.created_timestamp DESC
            ) rn

        FROM record_transformation_journey j

        WHERE j.batch_id = :batch_id
    ) x
    WHERE rn = 1
)

SELECT
    identifier,
    mtcn,
    batch_id,
    rpt_grp_id,

    stage,
    status,

    comments,
    skip_reason,

    processing_complete,

    created_timestamp,
    modified_timestamp,

    reporting_timestamp_latest,

    txn_metadata

FROM latest_stage

WHERE UPPER(stage) = 'TRANSFORMATION'

  AND UPPER(COALESCE(status,''))
        IN ('FAILURE','FAILED')

ORDER BY modified_timestamp DESC;
```

---

# 16. Attempt Not Received Detail

## Question Answered

**Which transactions were unavailable or failed during transaction join?**

```sql
WITH latest_stage AS (
    SELECT *
    FROM (
        SELECT
            j.*,

            ROW_NUMBER() OVER (
                PARTITION BY
                    j.identifier,
                    j.stage
                ORDER BY
                    j.modified_timestamp DESC,
                    j.created_timestamp DESC
            ) rn

        FROM record_transformation_journey j

        WHERE j.batch_id = :batch_id
    ) x

    WHERE rn = 1
)

SELECT
    identifier,
    mtcn,
    rpt_grp_id,
    batch_id,

    stage,
    status,

    comments,
    skip_reason,

    created_timestamp,
    modified_timestamp,

    txn_metadata

FROM latest_stage

WHERE UPPER(stage) = 'TRANSACTION_JOIN'

  AND (
        UPPER(COALESCE(status,'')) = 'ERROR'

        OR COALESCE(skip_reason,'')
            ILIKE '%not yet recorded%'
      )

ORDER BY modified_timestamp DESC;
```

---

# 17. Complete Transaction Journey

## Question Answered

**For a selected transaction, what happened across all processing stages?**

```sql
SELECT
    identifier,
    mtcn,

    rpt_grp_id,
    batch_id,

    stage,
    status,

    comments,
    skip_reason,

    processing_complete,

    created_timestamp,
    modified_timestamp,

    reporting_timestamp_latest,

    txn_metadata

FROM record_transformation_journey

WHERE batch_id = :batch_id

  AND (
        identifier = :identifier
        OR mtcn = :mtcn
      )

ORDER BY
    created_timestamp,
    modified_timestamp;
```

---

# 18. Rule Hit Detail for the Transaction

## Question Answered

**What rule-hit information exists for the selected transaction?**

```sql
SELECT
    rh.rpt_grp_id,
    rh.rpt_grp_name,

    rh.rule_id,
    rh.attempt_id,

    rh.external_txn_key,
    rh.galactic_id,
    rh.mtcn,

    rh.activity_type,

    rh.exclusion_reason_id,
    rh.is_reported,

    rh.batch_id,
    rh.efile_batch_id,
    rh.reported_batch_id,

    rh.transaction_date,
    rh.reporting_timestamp,

    rh.source,
    rh.transaction_side

FROM rule_hit rh

WHERE rh.rpt_grp_id = :rpt_grp_id

  AND (
        rh.mtcn = :mtcn

        OR rh.external_txn_key::text
             = :external_txn_key
      );
```

### Important

Do not assume that a field from `record_transformation_journey.txn_metadata` maps to `external_txn_key` until the relationship is validated.

---

# 19. Exclusion Audit Detail

## Question Answered

**Was the selected transaction excluded? If yes, why and by what strategy?**

```sql
SELECT
    attempt_id,
    rpt_grp_id,
    rpt_grp_name,

    rule_id,
    bucket_id,

    external_txn_key,
    mtcn,

    processing_batch_id,

    exclusion_reason_id,
    exclusion_strategy,

    reported_batch_id,

    reporting_timestamp,

    created_timestamp,
    modified_timestamp

FROM rule_hit_exclusion_audit

WHERE rpt_grp_id = :rpt_grp_id

  AND (
        mtcn = :mtcn
        OR external_txn_key::text = :external_txn_key
      )

ORDER BY modified_timestamp DESC;
```

---

# 20. Rule-Level Breakdown for a Batch

## Question Answered

**For a report group and batch, which rules produced hits, how many were reported, excluded, or not reported?**

```sql
SELECT
    rule_id,

    COUNT(*) AS rule_hits,

    COUNT(*) FILTER (
        WHERE exclusion_reason_id IS NOT NULL
    ) AS excluded,

    COUNT(*) FILTER (
        WHERE is_reported = TRUE
    ) AS reported,

    COUNT(*) FILTER (
        WHERE is_reported = FALSE
    ) AS not_reported

FROM rule_hit

WHERE rpt_grp_id = :rpt_grp_id
  AND batch_id = :batch_id

GROUP BY rule_id

ORDER BY not_reported DESC, rule_hits DESC;
```

### Important Validation Needed

This query should only be used in production after confirming:

```text
rule_hit.batch_id
```

represents the same business batch as:

```text
report_transformation_reconciliation.batch_id
```

If the actual bridge is `efile_batch_id`, `reported_batch_id`, or `processing_batch_id`, the query must be changed accordingly.

---

# 21. Dashboard → Drill-Down Query Flow

```text
PERIOD DASHBOARD
    ↓
Main KPI Summary
    Query 3 / Query 5

    ↓
REPORT GROUP HEALTH
    Query 8

    ↓
REPORT GROUP DETAIL
    Query 11

    ↓
BATCH INVESTIGATION
    Query 12

    ├── Stage / Status
    │      Query 13
    │
    ├── Failure Reasons
    │      Query 14
    │
    ├── Transformation Failures
    │      Query 15
    │
    └── Attempt / Join Issues
           Query 16

    ↓
TRANSACTION JOURNEY
    Query 17

    ├── Rule Hit Detail
    │      Query 18
    │
    └── Exclusion Audit
           Query 19
```

---

# 22. Dashboard Component → Query Mapping

| Dashboard / Drill-Down Area | Query |
|---|---|
| Batches Run | Query 3 / 5 |
| Report Groups Run | Query 3 / 5 |
| Batches With Issues | Query 3 / 5 |
| Expected Rule Hits | Query 4 / 5 |
| Matched Rule Hits | Query 4 / 5 |
| Missed Rule Hits | Query 4 / 5 |
| Transformation Failures | Query 3 / 5 |
| Reconciliation Issue Batches | Query 3 / 5 |
| Batch Health Distribution | Query 6 |
| Issues by Type | Query 7 |
| Report Group Health | Query 8 |
| Problem Batches | Query 9 |
| Operations Trend | Query 10 |
| Report Group Batch List | Query 11 |
| Batch Control Summary | Query 12 |
| Batch Stage / Status | Query 13 |
| Failure Reason Breakdown | Query 14 |
| Transformation Failure Records | Query 15 |
| Attempt Not Received Records | Query 16 |
| Transaction Journey | Query 17 |
| Rule-Hit Transaction Detail | Query 18 |
| Exclusion Audit Detail | Query 19 |
| Rule-Level Batch Summary | Query 20 |

---

# 23. Recommended Filter Behavior

The dashboard should support:

- Date Range
- Report Group
- Batch Status
- Batch ID
- Rule
- Issue Type
- Processing Stage
- Transaction Key / MTCN / External Txn Key / Galactic ID
- Source / Channel
- Country / Corridor if derivable from available data

## Filter Rules

### Date Range

For batch activity:

```text
report_transformation_reconciliation.created_timestamp
```

For rule reconciliation:

```text
rule_hit_reconciliation.run_date
```

Do not silently treat these as the same physical timestamp.

### Report Group

Use:

```text
rpt_grp_id
```

as the primary key.

### Batch

Use:

```text
batch_id
```

for transformation and journey queries.

### Rule

Use:

```text
rule_hit.rule_id
```

after the batch bridge is confirmed.

---

# 24. Production Data Rules

1. **Always deduplicate batch reconciliation rows by latest `seq_no` / `modified_timestamp`.**

2. **Use latest transaction-stage state when analyzing `record_transformation_journey`.**

3. **Prefer `COUNT(DISTINCT identifier)` over raw journey row counts for transaction counts.**

4. **Do not classify `txn_missing_attempt_count` as a join-error count until its grain is validated.**

5. **Do not add unrelated issue counters together merely to create one “Processing Exceptions” number.**

6. **A batch may have multiple issue types.**

7. **Every red/amber KPI should drill to affected report groups or batches.**

8. **Every problem batch should drill to transaction-level evidence.**

9. **Every transaction should expose its end-to-end journey and root-cause information.**

10. **Validate the batch bridge between `rule_hit` and transformation tables before productionizing rule-level batch analysis.**

---

# 25. Target Investigation Flow

The final user experience should support:

```text
Selected Period
      ↓
Which report groups ran?
      ↓
Which report groups had problematic batches?
      ↓
Which batch had an issue?
      ↓
What control failed?
      ↓
Which rule / transaction was affected?
      ↓
What happened to the transaction?
      ↓
Why did it fail, skip, or get excluded?
      ↓
What evidence exists in the journey / audit tables?
```

This is the core compliance Operations investigation model for the dashboard.
