Yes. At this point I want to validate the **database against the code we just reviewed**, rather than do more code archaeology.

Use **June 2026** for all of these. Every query below returns **exactly one row with one JSONB column named `result`**. You can paste the JSON result back here one by one or several at a time.

The most important ones are **Q01–Q10**. Q11–Q12 are the final discovery checks that could improve Phase 1.

### Q01 — Confirm `report_batch_info` join and dashboard timestamp

This establishes whether `(rpt_grp_id, batch_id, seq_no)` really joins the two batch tables and whether `process_timestamp` can safely become our dashboard execution timestamp.

```sql
WITH params AS (
    SELECT
        TIMESTAMP '2026-06-01 00:00:00' AS from_ts,
        TIMESTAMP '2026-07-01 00:00:00' AS to_ts
),
latest_rtr AS (
    SELECT DISTINCT ON (rpt_grp_id, batch_id)
        rpt_grp_id,
        rpt_grp_name,
        batch_id,
        seq_no,
        created_timestamp,
        modified_timestamp
    FROM pharos.report_transformation_reconciliation rtr
    CROSS JOIN params p
    WHERE rtr.created_timestamp >= p.from_ts
      AND rtr.created_timestamp <  p.to_ts
    ORDER BY
        rpt_grp_id,
        batch_id,
        seq_no DESC,
        modified_timestamp DESC NULLS LAST
),
joined AS (
    SELECT
        r.*,
        bi.batch_id AS bi_batch_id,
        bi.seq_no AS bi_seq_no,
        bi.process_timestamp,
        bi.created_timestamp AS batch_info_created_timestamp,
        bi.batch_status,
        bi.compiler_status,
        bi.report_status,
        bi.txn_lookback_start_timestamp,
        bi.txn_start_timestamp,
        bi.txn_end_timestamp
    FROM latest_rtr r
    LEFT JOIN pharos.report_batch_info bi
        ON bi.rpt_grp_id = r.rpt_grp_id
       AND bi.batch_id   = r.batch_id
       AND bi.seq_no     = r.seq_no
)
SELECT jsonb_build_object(
    'query_id', 'VAL_01_BATCH_JOIN_AND_TIME',

    'transformation_batches', COUNT(*),

    'exact_report_batch_info_matches',
        COUNT(*) FILTER (WHERE bi_batch_id IS NOT NULL),

    'unmatched_batches',
        COUNT(*) FILTER (WHERE bi_batch_id IS NULL),

    'process_timestamp_null',
        COUNT(*) FILTER (
            WHERE bi_batch_id IS NOT NULL
              AND process_timestamp IS NULL
        ),

    'process_timestamp_in_june',
        COUNT(*) FILTER (
            WHERE process_timestamp >= TIMESTAMP '2026-06-01 00:00:00'
              AND process_timestamp <  TIMESTAMP '2026-07-01 00:00:00'
        ),

    'process_timestamp_outside_june',
        COUNT(*) FILTER (
            WHERE process_timestamp IS NOT NULL
              AND NOT (
                  process_timestamp >= TIMESTAMP '2026-06-01 00:00:00'
                  AND process_timestamp < TIMESTAMP '2026-07-01 00:00:00'
              )
        ),

    'batch_status_counts',
        (
            SELECT COALESCE(
                jsonb_object_agg(status_value, cnt),
                '{}'::jsonb
            )
            FROM (
                SELECT
                    COALESCE(batch_status, '<NULL>') AS status_value,
                    COUNT(*) AS cnt
                FROM joined
                WHERE bi_batch_id IS NOT NULL
                GROUP BY COALESCE(batch_status, '<NULL>')
            ) x
        ),

    'unmatched_samples',
        (
            SELECT COALESCE(jsonb_agg(to_jsonb(x)), '[]'::jsonb)
            FROM (
                SELECT
                    rpt_grp_id,
                    rpt_grp_name,
                    batch_id,
                    seq_no,
                    created_timestamp
                FROM joined
                WHERE bi_batch_id IS NULL
                ORDER BY created_timestamp DESC
                LIMIT 10
            ) x
        ),

    'timing_samples',
        (
            SELECT COALESCE(jsonb_agg(to_jsonb(x)), '[]'::jsonb)
            FROM (
                SELECT
                    rpt_grp_id,
                    rpt_grp_name,
                    batch_id,
                    seq_no,
                    created_timestamp AS reconciliation_created_timestamp,
                    process_timestamp,
                    batch_info_created_timestamp,
                    batch_status,
                    compiler_status,
                    report_status
                FROM joined
                WHERE bi_batch_id IS NOT NULL
                ORDER BY process_timestamp DESC NULLS LAST
                LIMIT 15
            ) x
        )
) AS result
FROM joined;
```

### Q02 — Revalidate all batch control equations using the actual code semantics

This is particularly important because the code review changed one thing: **duplicate transformations are a separate quality metric, not part of the primary transformation balance equation**.

```sql
WITH latest_rtr AS (
    SELECT DISTINCT ON (rpt_grp_id, batch_id)
        *
    FROM pharos.report_transformation_reconciliation
    WHERE created_timestamp >= TIMESTAMP '2026-06-01 00:00:00'
      AND created_timestamp <  TIMESTAMP '2026-07-01 00:00:00'
    ORDER BY
        rpt_grp_id,
        batch_id,
        seq_no DESC,
        modified_timestamp DESC NULLS LAST
)
SELECT jsonb_build_object(
    'query_id', 'VAL_02_BATCH_CONTROL_EQUATIONS',

    'total_batches', COUNT(*),

    'reportable_balanced',
        COUNT(*) FILTER (
            WHERE COALESCE(actual_reportable_txn, 0)
                = COALESCE(expected_reportable_txn, 0)
        ),

    'reportable_unbalanced',
        COUNT(*) FILTER (
            WHERE COALESCE(actual_reportable_txn, 0)
               <> COALESCE(expected_reportable_txn, 0)
        ),

    'lookback_balanced',
        COUNT(*) FILTER (
            WHERE COALESCE(lookback_txn, 0)
                = COALESCE(lookback_actual_txn, 0)
                + COALESCE(lookback_future_reporting_txn, 0)
        ),

    'lookback_unbalanced',
        COUNT(*) FILTER (
            WHERE COALESCE(lookback_txn, 0)
               <> COALESCE(lookback_actual_txn, 0)
                + COALESCE(lookback_future_reporting_txn, 0)
        ),

    'reporting_period_balanced',
        COUNT(*) FILTER (
            WHERE COALESCE(reporting_period_txn, 0)
                = COALESCE(reporting_period_actual_txn, 0)
                + COALESCE(reporting_period_future_reporting_txn, 0)
        ),

    'reporting_period_unbalanced',
        COUNT(*) FILTER (
            WHERE COALESCE(reporting_period_txn, 0)
               <> COALESCE(reporting_period_actual_txn, 0)
                + COALESCE(reporting_period_future_reporting_txn, 0)
        ),

    'activity_selected_balanced',
        COUNT(*) FILTER (
            WHERE COALESCE(activity_selected, 0)
                = COALESCE(lookback_txn, 0)
                + COALESCE(reporting_period_txn, 0)
                + COALESCE(activity_simulated, 0)
        ),

    'activity_selected_unbalanced',
        COUNT(*) FILTER (
            WHERE COALESCE(activity_selected, 0)
               <> COALESCE(lookback_txn, 0)
                + COALESCE(reporting_period_txn, 0)
                + COALESCE(activity_simulated, 0)
        ),

    'transformation_balance_code_formula',
        jsonb_build_object(
            'formula',
            'actual_activity_eligible_for_transformation = activity_transformed + activity_transformation_failed',

            'balanced',
            COUNT(*) FILTER (
                WHERE COALESCE(actual_activity_eligible_for_transformation, 0)
                    = COALESCE(activity_transformed, 0)
                    + COALESCE(activity_transformation_failed, 0)
            ),

            'unbalanced',
            COUNT(*) FILTER (
                WHERE COALESCE(actual_activity_eligible_for_transformation, 0)
                   <> COALESCE(activity_transformed, 0)
                    + COALESCE(activity_transformation_failed, 0)
            )
        ),

    'transformation_balance_with_duplicate',
        jsonb_build_object(
            'formula',
            'actual_activity_eligible_for_transformation = activity_transformed + activity_transformation_failed + duplicate_transformation',

            'balanced',
            COUNT(*) FILTER (
                WHERE COALESCE(actual_activity_eligible_for_transformation, 0)
                    = COALESCE(activity_transformed, 0)
                    + COALESCE(activity_transformation_failed, 0)
                    + COALESCE(duplicate_transformation, 0)
            ),

            'unbalanced',
            COUNT(*) FILTER (
                WHERE COALESCE(actual_activity_eligible_for_transformation, 0)
                   <> COALESCE(activity_transformed, 0)
                    + COALESCE(activity_transformation_failed, 0)
                    + COALESCE(duplicate_transformation, 0)
            )
        ),

    'largest_control_mismatches',
        (
            SELECT COALESCE(jsonb_agg(to_jsonb(x)), '[]'::jsonb)
            FROM (
                SELECT
                    rpt_grp_id,
                    rpt_grp_name,
                    batch_id,

                    expected_reportable_txn,
                    actual_reportable_txn,
                    COALESCE(actual_reportable_txn, 0)
                      - COALESCE(expected_reportable_txn, 0)
                        AS reportable_difference,

                    activity_selected,
                    lookback_txn,
                    reporting_period_txn,
                    activity_simulated,

                    actual_activity_eligible_for_transformation,
                    activity_transformed,
                    activity_transformation_failed,
                    duplicate_transformation,

                    COALESCE(actual_activity_eligible_for_transformation, 0)
                      - COALESCE(activity_transformed, 0)
                      - COALESCE(activity_transformation_failed, 0)
                        AS code_transformation_difference

                FROM latest_rtr
                WHERE
                    COALESCE(actual_reportable_txn, 0)
                        <> COALESCE(expected_reportable_txn, 0)

                    OR COALESCE(activity_selected, 0)
                        <> COALESCE(lookback_txn, 0)
                         + COALESCE(reporting_period_txn, 0)
                         + COALESCE(activity_simulated, 0)

                    OR COALESCE(actual_activity_eligible_for_transformation, 0)
                        <> COALESCE(activity_transformed, 0)
                         + COALESCE(activity_transformation_failed, 0)

                ORDER BY
                    ABS(
                        COALESCE(actual_reportable_txn, 0)
                        - COALESCE(expected_reportable_txn, 0)
                    ) DESC
                LIMIT 20
            ) x
        )
) AS result
FROM latest_rtr;
```

### Q03 — Validate future-reporting aggregate metrics

For Phase 1, this tells us whether these metrics are worth surfacing. The **count is safe**; exact row-level click-through remains strategy/config dependent.

```sql
WITH latest_rtr AS (
    SELECT DISTINCT ON (rpt_grp_id, batch_id)
        *
    FROM pharos.report_transformation_reconciliation
    WHERE created_timestamp >= TIMESTAMP '2026-06-01 00:00:00'
      AND created_timestamp <  TIMESTAMP '2026-07-01 00:00:00'
    ORDER BY
        rpt_grp_id,
        batch_id,
        seq_no DESC,
        modified_timestamp DESC NULLS LAST
)
SELECT jsonb_build_object(
    'query_id', 'VAL_03_FUTURE_REPORTING',

    'total_batches', COUNT(*),

    'batches_with_lookback_future_reporting',
        COUNT(*) FILTER (
            WHERE COALESCE(lookback_future_reporting_txn, 0) > 0
        ),

    'batches_with_reporting_period_future_reporting',
        COUNT(*) FILTER (
            WHERE COALESCE(reporting_period_future_reporting_txn, 0) > 0
        ),

    'batches_with_any_future_reporting',
        COUNT(*) FILTER (
            WHERE COALESCE(lookback_future_reporting_txn, 0)
                + COALESCE(reporting_period_future_reporting_txn, 0) > 0
        ),

    'sum_lookback_txn',
        COALESCE(SUM(lookback_txn), 0),

    'sum_lookback_actual_txn',
        COALESCE(SUM(lookback_actual_txn), 0),

    'sum_lookback_future_reporting_txn',
        COALESCE(SUM(lookback_future_reporting_txn), 0),

    'sum_reporting_period_txn',
        COALESCE(SUM(reporting_period_txn), 0),

    'sum_reporting_period_actual_txn',
        COALESCE(SUM(reporting_period_actual_txn), 0),

    'sum_reporting_period_future_reporting_txn',
        COALESCE(SUM(reporting_period_future_reporting_txn), 0),

    'largest_future_reporting_batches',
        (
            SELECT COALESCE(jsonb_agg(to_jsonb(x)), '[]'::jsonb)
            FROM (
                SELECT
                    rpt_grp_id,
                    rpt_grp_name,
                    batch_id,

                    lookback_txn,
                    lookback_actual_txn,
                    lookback_future_reporting_txn,

                    reporting_period_txn,
                    reporting_period_actual_txn,
                    reporting_period_future_reporting_txn,

                    COALESCE(lookback_future_reporting_txn, 0)
                    + COALESCE(reporting_period_future_reporting_txn, 0)
                        AS total_future_reporting

                FROM latest_rtr

                WHERE
                    COALESCE(lookback_future_reporting_txn, 0)
                    + COALESCE(reporting_period_future_reporting_txn, 0) > 0

                ORDER BY total_future_reporting DESC
                LIMIT 20
            ) x
        )
) AS result
FROM latest_rtr;
```

### Q04 — Prove `already_reported_count` against journey evidence

This validates the exact Phase 1 drill-down.

```sql
WITH scope AS (
    SELECT DISTINCT ON (rpt_grp_id, batch_id)
        rpt_grp_id,
        rpt_grp_name,
        batch_id,
        already_reported_count
    FROM pharos.report_transformation_reconciliation
    WHERE created_timestamp >= TIMESTAMP '2026-06-01 00:00:00'
      AND created_timestamp <  TIMESTAMP '2026-07-01 00:00:00'
    ORDER BY
        rpt_grp_id,
        batch_id,
        seq_no DESC,
        modified_timestamp DESC NULLS LAST
),
journey_stats AS (
    SELECT
        j.rpt_grp_id,
        j.batch_id,

        COUNT(*) AS journey_rows,

        COUNT(*) FILTER (
            WHERE j.stage = 'FILTRATION'
              AND j.status = 'EXCLUDED'
              AND j.comments = 'EXCLUDED_BECAUSE_ALREADY_REPORTED(PHAROS)'
        ) AS already_reported_journey_rows

    FROM pharos.record_transformation_journey j

    JOIN scope s
      ON s.rpt_grp_id = j.rpt_grp_id
     AND s.batch_id   = j.batch_id

    GROUP BY
        j.rpt_grp_id,
        j.batch_id
),
comparison AS (
    SELECT
        s.*,
        COALESCE(js.journey_rows, 0) AS journey_rows,
        COALESCE(js.already_reported_journey_rows, 0)
            AS already_reported_journey_rows
    FROM scope s
    LEFT JOIN journey_stats js
      ON js.rpt_grp_id = s.rpt_grp_id
     AND js.batch_id   = s.batch_id
)
SELECT jsonb_build_object(
    'query_id', 'VAL_04_ALREADY_REPORTED_JOURNEY',

    'total_batches', COUNT(*),

    'batches_with_any_journey',
        COUNT(*) FILTER (WHERE journey_rows > 0),

    'batches_with_metric_nonzero',
        COUNT(*) FILTER (
            WHERE COALESCE(already_reported_count, 0) > 0
        ),

    'exactly_balanced_all_batches',
        COUNT(*) FILTER (
            WHERE COALESCE(already_reported_count, 0)
                = already_reported_journey_rows
        ),

    'balanced_when_journey_exists',
        COUNT(*) FILTER (
            WHERE journey_rows > 0
              AND COALESCE(already_reported_count, 0)
                  = already_reported_journey_rows
        ),

    'metric_nonzero_marker_zero',
        COUNT(*) FILTER (
            WHERE COALESCE(already_reported_count, 0) > 0
              AND already_reported_journey_rows = 0
        ),

    'mismatches',
        (
            SELECT COALESCE(jsonb_agg(to_jsonb(x)), '[]'::jsonb)
            FROM (
                SELECT *
                FROM comparison
                WHERE COALESCE(already_reported_count, 0)
                    <> already_reported_journey_rows
                ORDER BY COALESCE(already_reported_count, 0) DESC
                LIMIT 25
            ) x
        )
) AS result
FROM comparison;
```

### Q05 — Prove `txn_missing_attempt_count` against journey evidence

This will also tell us how often the config-dependent branch prevents row-level evidence.

```sql
WITH scope AS (
    SELECT DISTINCT ON (rpt_grp_id, batch_id)
        rpt_grp_id,
        rpt_grp_name,
        batch_id,
        txn_missing_attempt_count
    FROM pharos.report_transformation_reconciliation
    WHERE created_timestamp >= TIMESTAMP '2026-06-01 00:00:00'
      AND created_timestamp <  TIMESTAMP '2026-07-01 00:00:00'
    ORDER BY
        rpt_grp_id,
        batch_id,
        seq_no DESC,
        modified_timestamp DESC NULLS LAST
),
journey_stats AS (
    SELECT
        j.rpt_grp_id,
        j.batch_id,

        COUNT(*) AS journey_rows,

        COUNT(*) FILTER (
            WHERE j.stage = 'TRANSACTION_JOIN'
              AND j.status = 'ERROR'
              AND j.comments = 'ATTEMPT_NOT_RECEIVED'
        ) AS missing_attempt_journey_rows

    FROM pharos.record_transformation_journey j

    JOIN scope s
      ON s.rpt_grp_id = j.rpt_grp_id
     AND s.batch_id   = j.batch_id

    GROUP BY
        j.rpt_grp_id,
        j.batch_id
),
comparison AS (
    SELECT
        s.*,
        COALESCE(js.journey_rows, 0) AS journey_rows,
        COALESCE(js.missing_attempt_journey_rows, 0)
            AS missing_attempt_journey_rows
    FROM scope s
    LEFT JOIN journey_stats js
      ON js.rpt_grp_id = s.rpt_grp_id
     AND js.batch_id   = s.batch_id
)
SELECT jsonb_build_object(
    'query_id', 'VAL_05_MISSING_ATTEMPT_JOURNEY',

    'total_batches', COUNT(*),

    'batches_with_any_journey',
        COUNT(*) FILTER (WHERE journey_rows > 0),

    'batches_with_missing_attempt_metric',
        COUNT(*) FILTER (
            WHERE COALESCE(txn_missing_attempt_count, 0) > 0
        ),

    'exactly_balanced_all_batches',
        COUNT(*) FILTER (
            WHERE COALESCE(txn_missing_attempt_count, 0)
                = missing_attempt_journey_rows
        ),

    'balanced_when_journey_exists',
        COUNT(*) FILTER (
            WHERE journey_rows > 0
              AND COALESCE(txn_missing_attempt_count, 0)
                  = missing_attempt_journey_rows
        ),

    'metric_nonzero_marker_zero',
        COUNT(*) FILTER (
            WHERE COALESCE(txn_missing_attempt_count, 0) > 0
              AND missing_attempt_journey_rows = 0
        ),

    'mismatches',
        (
            SELECT COALESCE(jsonb_agg(to_jsonb(x)), '[]'::jsonb)
            FROM (
                SELECT *
                FROM comparison
                WHERE COALESCE(txn_missing_attempt_count, 0)
                    <> missing_attempt_journey_rows
                ORDER BY COALESCE(txn_missing_attempt_count, 0) DESC
                LIMIT 25
            ) x
        )
) AS result
FROM comparison;
```

### Q06 — Validate transformed/failed counts against journey evidence

This validates how strongly the transformation-success and transformation-failure KPIs can support row-level click-through.

```sql
WITH scope AS (
    SELECT DISTINCT ON (rpt_grp_id, batch_id)
        rpt_grp_id, rpt_grp_name, batch_id,
        activity_transformed, activity_transformation_failed,
        duplicate_transformation
    FROM pharos.report_transformation_reconciliation
    WHERE created_timestamp >= TIMESTAMP '2026-06-01 00:00:00'
      AND created_timestamp <  TIMESTAMP '2026-07-01 00:00:00'
    ORDER BY rpt_grp_id, batch_id, seq_no DESC,
             modified_timestamp DESC NULLS LAST
), journey_stats AS (
    SELECT j.rpt_grp_id, j.batch_id, COUNT(*) AS journey_rows,
        COUNT(*) FILTER (
            WHERE j.stage = 'TRANSFORMATION' AND j.status = 'SUCCESS'
        ) AS transformed_journey_rows,
        COUNT(*) FILTER (
            WHERE j.stage = 'TRANSFORMATION' AND j.status = 'FAILURE'
              AND j.comments = 'TRANSFORMATION_SKIPPED'
        ) AS failed_journey_rows
    FROM pharos.record_transformation_journey j
    JOIN scope s ON s.rpt_grp_id = j.rpt_grp_id AND s.batch_id = j.batch_id
    GROUP BY j.rpt_grp_id, j.batch_id
), comparison AS (
    SELECT s.*, COALESCE(js.journey_rows, 0) AS journey_rows,
        COALESCE(js.transformed_journey_rows, 0) AS transformed_journey_rows,
        COALESCE(js.failed_journey_rows, 0) AS failed_journey_rows
    FROM scope s
    LEFT JOIN journey_stats js
      ON js.rpt_grp_id = s.rpt_grp_id AND js.batch_id = s.batch_id
)
SELECT jsonb_build_object(
    'query_id', 'VAL_06_TRANSFORMATION_JOURNEY',
    'total_batches', COUNT(*),
    'batches_with_any_journey', COUNT(*) FILTER (WHERE journey_rows > 0),
    'transformed_exactly_balanced', COUNT(*) FILTER (
        WHERE COALESCE(activity_transformed, 0) = transformed_journey_rows
    ),
    'failed_exactly_balanced', COUNT(*) FILTER (
        WHERE COALESCE(activity_transformation_failed, 0) = failed_journey_rows
    ),
    'mismatches', (
        SELECT COALESCE(jsonb_agg(to_jsonb(x)), '[]'::jsonb)
        FROM (
            SELECT * FROM comparison
            WHERE COALESCE(activity_transformed, 0) <> transformed_journey_rows
               OR COALESCE(activity_transformation_failed, 0) <> failed_journey_rows
            ORDER BY COALESCE(activity_transformation_failed, 0) DESC
            LIMIT 25
        ) x
    )
) AS result
FROM comparison;
```

### Q07 — Validate duplicate transformation as a separate quality signal

This confirms prevalence and scale without folding duplicates into the primary transformation balance equation.

```sql
WITH latest_rtr AS (
    SELECT DISTINCT ON (rpt_grp_id, batch_id) *
    FROM pharos.report_transformation_reconciliation
    WHERE created_timestamp >= TIMESTAMP '2026-06-01 00:00:00'
      AND created_timestamp <  TIMESTAMP '2026-07-01 00:00:00'
    ORDER BY rpt_grp_id, batch_id, seq_no DESC,
             modified_timestamp DESC NULLS LAST
)
SELECT jsonb_build_object(
    'query_id', 'VAL_07_DUPLICATE_TRANSFORMATION',
    'total_batches', COUNT(*),
    'batches_with_duplicates', COUNT(*) FILTER (
        WHERE COALESCE(duplicate_transformation, 0) > 0
    ),
    'total_duplicates', COALESCE(SUM(duplicate_transformation), 0),
    'largest_duplicate_batches', (
        SELECT COALESCE(jsonb_agg(to_jsonb(x)), '[]'::jsonb)
        FROM (
            SELECT rpt_grp_id, rpt_grp_name, batch_id,
                   duplicate_transformation, activity_transformed,
                   activity_transformation_failed
            FROM latest_rtr
            WHERE COALESCE(duplicate_transformation, 0) > 0
            ORDER BY duplicate_transformation DESC LIMIT 25
        ) x
    )
) AS result
FROM latest_rtr;
```

### Q08 — Validate rule-hit batch linkage and unreported population

This checks whether rule-hit evidence can be joined to a transformation batch and confirms the transformer-side `is_reported = false` population.

```sql
WITH scope AS (
    SELECT DISTINCT rpt_grp_id, batch_id
    FROM pharos.report_transformation_reconciliation
    WHERE created_timestamp >= TIMESTAMP '2026-06-01 00:00:00'
      AND created_timestamp <  TIMESTAMP '2026-07-01 00:00:00'
), rule_hits AS (
    SELECT rh.*
    FROM pharos.rule_hit rh
    JOIN scope s ON s.rpt_grp_id = rh.rpt_grp_id
                AND s.batch_id = rh.efile_batch_id
)
SELECT jsonb_build_object(
    'query_id', 'VAL_08_RULE_HIT_BATCH_LINKAGE',
    'rule_hit_rows', COUNT(*),
    'distinct_batches', COUNT(DISTINCT (rpt_grp_id, efile_batch_id)),
    'is_reported_false', COUNT(*) FILTER (WHERE is_reported IS FALSE),
    'is_reported_true', COUNT(*) FILTER (WHERE is_reported IS TRUE),
    'is_reported_null', COUNT(*) FILTER (WHERE is_reported IS NULL)
) AS result
FROM rule_hits;
```

### Q09 — Validate exclusion-audit coverage

This establishes whether excluded transactions have materialized audit evidence suitable for drill-down.

```sql
WITH scope AS (
    SELECT DISTINCT rpt_grp_id, batch_id
    FROM pharos.report_transformation_reconciliation
    WHERE created_timestamp >= TIMESTAMP '2026-06-01 00:00:00'
      AND created_timestamp <  TIMESTAMP '2026-07-01 00:00:00'
), audit_rows AS (
    SELECT ea.*
    FROM pharos.exclusion_audit ea
    JOIN scope s ON s.rpt_grp_id = ea.rpt_grp_id AND s.batch_id = ea.batch_id
)
SELECT jsonb_build_object(
    'query_id', 'VAL_09_EXCLUSION_AUDIT',
    'audit_rows', COUNT(*),
    'distinct_batches', COUNT(DISTINCT (rpt_grp_id, batch_id)),
    'reason_counts', (
        SELECT COALESCE(jsonb_object_agg(reason_value, cnt), '{}'::jsonb)
        FROM (
            SELECT COALESCE(exclusion_reason_id::text, '<NULL>') AS reason_value,
                   COUNT(*) AS cnt
            FROM audit_rows
            GROUP BY COALESCE(exclusion_reason_id::text, '<NULL>')
        ) x
    )
) AS result
FROM audit_rows;
```

### Q10 — Validate all reconciliation grains and control equations

This confirms the observed reconciliation types and validates Expected = Matched + Missed for each grain.

```sql
WITH scoped AS (
    SELECT *
    FROM pharos.rule_hit_reconciliation
    WHERE created_timestamp >= TIMESTAMP '2026-06-01 00:00:00'
      AND created_timestamp <  TIMESTAMP '2026-07-01 00:00:00'
)
SELECT jsonb_build_object(
    'query_id', 'VAL_10_RECONCILIATION_GRAINS',
    'total_rows', COUNT(*),
    'reconciliation_type_counts', (
        SELECT COALESCE(jsonb_object_agg(type_value, cnt), '{}'::jsonb)
        FROM (
            SELECT COALESCE(reconciliation_type, '<NULL>') AS type_value,
                   COUNT(*) AS cnt
            FROM scoped GROUP BY COALESCE(reconciliation_type, '<NULL>')
        ) x
    ),
    'balanced_rows', COUNT(*) FILTER (
        WHERE COALESCE(expected_count, 0)
            = COALESCE(matched_count, 0) + COALESCE(missed_count, 0)
    ),
    'unbalanced_rows', COUNT(*) FILTER (
        WHERE COALESCE(expected_count, 0)
           <> COALESCE(matched_count, 0) + COALESCE(missed_count, 0)
    )
) AS result
FROM scoped;
```

### Q11 — Discover production batch-status values

This is a discovery check before assigning dashboard meanings such as Healthy, Warning, Critical, or Failed.

```sql
WITH scoped AS (
    SELECT * FROM pharos.report_batch_info
    WHERE process_timestamp >= TIMESTAMP '2026-06-01 00:00:00'
      AND process_timestamp <  TIMESTAMP '2026-07-01 00:00:00'
)
SELECT jsonb_build_object(
    'query_id', 'DISC_11_BATCH_STATUS_VALUES',
    'total_rows', COUNT(*),
    'batch_status_counts', (
        SELECT COALESCE(jsonb_object_agg(v, cnt), '{}'::jsonb)
        FROM (SELECT COALESCE(batch_status, '<NULL>') v, COUNT(*) cnt
              FROM scoped GROUP BY COALESCE(batch_status, '<NULL>')) x
    ),
    'compiler_status_counts', (
        SELECT COALESCE(jsonb_object_agg(v, cnt), '{}'::jsonb)
        FROM (SELECT COALESCE(compiler_status, '<NULL>') v, COUNT(*) cnt
              FROM scoped GROUP BY COALESCE(compiler_status, '<NULL>')) x
    ),
    'report_status_counts', (
        SELECT COALESCE(jsonb_object_agg(v, cnt), '{}'::jsonb)
        FROM (SELECT COALESCE(report_status, '<NULL>') v, COUNT(*) cnt
              FROM scoped GROUP BY COALESCE(report_status, '<NULL>')) x
    )
) AS result
FROM scoped;
```

### Q12 — Discover reconciliation-detail candidate tables

This final discovery check determines whether any candidate table can support genuine row-level missed-hit drill-down.

```sql
WITH candidate_columns AS (
    SELECT table_schema, table_name, ordinal_position, column_name, data_type
    FROM information_schema.columns
    WHERE table_schema = 'pharos'
      AND table_name IN (
          'rule_hit_reconciliation_log',
          'rule_hit_reconciliation_analysis',
          'unprocessed_rule_hits'
      )
)
SELECT jsonb_build_object(
    'query_id', 'DISC_12_RECONCILIATION_DETAIL_TABLES',
    'tables_found', (
        SELECT COALESCE(jsonb_agg(DISTINCT table_name ORDER BY table_name),
                        '[]'::jsonb)
        FROM candidate_columns
    ),
    'columns', (
        SELECT COALESCE(jsonb_agg(
            jsonb_build_object(
                'table_schema', table_schema,
                'table_name', table_name,
                'ordinal_position', ordinal_position,
                'column_name', column_name,
                'data_type', data_type
            ) ORDER BY table_name, ordinal_position
        ), '[]'::jsonb)
        FROM candidate_columns
    )
) AS result;
```
