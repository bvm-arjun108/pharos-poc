WITH params AS (
    SELECT
        DATE '2026-08-01' AS start_date,
        DATE '2026-08-31' AS end_date
),

latest AS (
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
            ) AS rn

        FROM rule_hit_reconciliation r
        CROSS JOIN params p

        WHERE r.run_date >= TO_CHAR(p.start_date, 'YYYYMMDD')::INTEGER
          AND r.run_date <= TO_CHAR(p.end_date,   'YYYYMMDD')::INTEGER
    ) x

    WHERE rn = 1
),

analysis AS (
    SELECT
        rpt_grp_id,
        rpt_grp_name,
        run_date,
        seq_no,

        distinct_rule_hits_count_iwra,
        rule_hit_publish_count_iwra,
        distinct_rule_hits_count_pharos,
        missed_rule_hits_count_pharos,

        COALESCE(distinct_rule_hits_count_iwra, 0)
          - COALESCE(distinct_rule_hits_count_pharos, 0)
            AS distinct_iwra_minus_pharos,

        COALESCE(rule_hit_publish_count_iwra, 0)
          - COALESCE(distinct_rule_hits_count_pharos, 0)
            AS publish_minus_pharos,

        COALESCE(missed_rule_hits_count_pharos, 0)
          - (
                COALESCE(distinct_rule_hits_count_iwra, 0)
              - COALESCE(distinct_rule_hits_count_pharos, 0)
            )
            AS variance_vs_distinct_iwra,

        COALESCE(missed_rule_hits_count_pharos, 0)
          - (
                COALESCE(rule_hit_publish_count_iwra, 0)
              - COALESCE(distinct_rule_hits_count_pharos, 0)
            )
            AS variance_vs_publish

    FROM latest
)

SELECT jsonb_build_object(

    'query_id', 'VALIDATION_01_RULE_HIT_RECON',

    'period', jsonb_build_object(
        'start_date', '2026-08-01',
        'end_date',   '2026-08-31'
    ),

    'summary', jsonb_build_object(

        'total_reconciliation_rows',
            COUNT(*),

        'rows_where_distinct_equation_balances',
            COUNT(*) FILTER (
                WHERE variance_vs_distinct_iwra = 0
            ),

        'rows_where_publish_equation_balances',
            COUNT(*) FILTER (
                WHERE variance_vs_publish = 0
            ),

        'rows_where_distinct_equation_does_not_balance',
            COUNT(*) FILTER (
                WHERE variance_vs_distinct_iwra <> 0
            ),

        'rows_where_publish_equation_does_not_balance',
            COUNT(*) FILTER (
                WHERE variance_vs_publish <> 0
            )

    ),

    'rows',
        COALESCE(
            jsonb_agg(
                jsonb_build_object(

                    'rpt_grp_id', rpt_grp_id,
                    'rpt_grp_name', rpt_grp_name,
                    'run_date', run_date,
                    'seq_no', seq_no,

                    'distinct_rule_hits_count_iwra',
                        distinct_rule_hits_count_iwra,

                    'rule_hit_publish_count_iwra',
                        rule_hit_publish_count_iwra,

                    'distinct_rule_hits_count_pharos',
                        distinct_rule_hits_count_pharos,

                    'missed_rule_hits_count_pharos',
                        missed_rule_hits_count_pharos,

                    'distinct_iwra_minus_pharos',
                        distinct_iwra_minus_pharos,

                    'publish_minus_pharos',
                        publish_minus_pharos,

                    'variance_vs_distinct_iwra',
                        variance_vs_distinct_iwra,

                    'variance_vs_publish',
                        variance_vs_publish
                )
                ORDER BY rpt_grp_name, run_date
            ),
            '[]'::jsonb
        )

) AS validation_result

FROM analysis;



========================================================================================================================================================================================

    WITH params AS (
    SELECT
        DATE '2026-08-01' AS start_date,
        DATE '2026-08-31' AS end_date
),

latest AS (

    SELECT *
    FROM (

        SELECT
            r.*,

            ROW_NUMBER() OVER (
                PARTITION BY
                    r.batch_id,
                    r.rpt_grp_id
                ORDER BY
                    r.seq_no DESC,
                    r.modified_timestamp DESC
            ) AS rn

        FROM report_transformation_reconciliation r
        CROSS JOIN params p

        WHERE r.created_timestamp >= p.start_date
          AND r.created_timestamp < p.end_date + INTERVAL '1 day'

    ) x

    WHERE rn = 1
),

checks AS (

    SELECT
        *,

        COALESCE(txn_selected, 0)
          - (
                COALESCE(excluded_txn, 0)
              + COALESCE(txn_missing_attempt_count, 0)
              + COALESCE(already_reported_count, 0)
              + COALESCE(expected_reportable_txn, 0)
            )
            AS selection_balance_diff,

        COALESCE(actual_activity_eligible_for_transformation, 0)
          - (
                COALESCE(activity_transformed, 0)
              + COALESCE(activity_transformation_failed, 0)
              + COALESCE(duplicate_transformation, 0)
            )
            AS transformation_balance_diff

    FROM latest
),

summary AS (

    SELECT

        COUNT(*) AS total_batches,

        COUNT(*) FILTER (
            WHERE selection_balance_diff = 0
        ) AS selection_balanced_batches,

        COUNT(*) FILTER (
            WHERE selection_balance_diff <> 0
        ) AS selection_unbalanced_batches,

        COUNT(*) FILTER (
            WHERE transformation_balance_diff = 0
        ) AS transformation_balanced_batches,

        COUNT(*) FILTER (
            WHERE transformation_balance_diff <> 0
        ) AS transformation_unbalanced_batches,

        MAX(ABS(selection_balance_diff))
            AS max_selection_difference,

        MAX(ABS(transformation_balance_diff))
            AS max_transformation_difference

    FROM checks
)

SELECT jsonb_build_object(

    'query_id', 'VALIDATION_02_TRANSFORMATION_WATERFALL',

    'period', jsonb_build_object(
        'start_date', '2026-08-01',
        'end_date',   '2026-08-31'
    ),

    'summary', (
        SELECT jsonb_build_object(

            'total_batches',
                total_batches,

            'selection_balanced_batches',
                selection_balanced_batches,

            'selection_unbalanced_batches',
                selection_unbalanced_batches,

            'transformation_balanced_batches',
                transformation_balanced_batches,

            'transformation_unbalanced_batches',
                transformation_unbalanced_batches,

            'max_selection_difference',
                max_selection_difference,

            'max_transformation_difference',
                max_transformation_difference

        )
        FROM summary
    ),

    'batch_details',

        COALESCE(
            (
                SELECT jsonb_agg(
                    jsonb_build_object(

                        'batch_id',
                            batch_id,

                        'rpt_grp_id',
                            rpt_grp_id,

                        'rpt_grp_name',
                            rpt_grp_name,

                        'txn_selected',
                            txn_selected,

                        'excluded_txn',
                            excluded_txn,

                        'txn_missing_attempt_count',
                            txn_missing_attempt_count,

                        'already_reported_count',
                            already_reported_count,

                        'expected_reportable_txn',
                            expected_reportable_txn,

                        'selection_balance_diff',
                            selection_balance_diff,

                        'actual_activity_eligible_for_transformation',
                            actual_activity_eligible_for_transformation,

                        'activity_transformed',
                            activity_transformed,

                        'activity_transformation_failed',
                            activity_transformation_failed,

                        'duplicate_transformation',
                            duplicate_transformation,

                        'transformation_balance_diff',
                            transformation_balance_diff

                    )
                    ORDER BY
                        ABS(selection_balance_diff) DESC,
                        ABS(transformation_balance_diff) DESC
                )
                FROM checks
            ),
            '[]'::jsonb
        )

) AS validation_result;







========================================================================================================================================================================================

WITH params AS (
    SELECT
        DATE '2026-08-01' AS start_date,
        DATE '2026-08-31' AS end_date
),

transformation_batches AS (

    SELECT DISTINCT
        r.rpt_grp_id,
        r.batch_id

    FROM report_transformation_reconciliation r
    CROSS JOIN params p

    WHERE r.batch_id IS NOT NULL

      AND r.created_timestamp >= p.start_date
      AND r.created_timestamp < p.end_date + INTERVAL '1 day'
),

bridge_test AS (

    /* Candidate 1 */
    SELECT
        'rule_hit.batch_id' AS candidate_bridge,

        COUNT(*) AS matched_rows,

        COUNT(
            DISTINCT (
                rh.rpt_grp_id,
                rh.batch_id
            )
        ) AS matched_batch_keys

    FROM rule_hit rh

    JOIN transformation_batches tb
      ON tb.rpt_grp_id = rh.rpt_grp_id
     AND tb.batch_id = rh.batch_id::text


    UNION ALL


    /* Candidate 2 */
    SELECT
        'rule_hit.efile_batch_id',

        COUNT(*),

        COUNT(
            DISTINCT (
                rh.rpt_grp_id,
                rh.efile_batch_id
            )
        )

    FROM rule_hit rh

    JOIN transformation_batches tb
      ON tb.rpt_grp_id = rh.rpt_grp_id
     AND tb.batch_id = rh.efile_batch_id


    UNION ALL


    /* Candidate 3 */
    SELECT
        'rule_hit.reported_batch_id',

        COUNT(*),

        COUNT(
            DISTINCT (
                rh.rpt_grp_id,
                rh.reported_batch_id
            )
        )

    FROM rule_hit rh

    JOIN transformation_batches tb
      ON tb.rpt_grp_id = rh.rpt_grp_id
     AND tb.batch_id = rh.reported_batch_id


    UNION ALL


    /* Candidate 4 */
    SELECT
        'exclusion_audit.processing_batch_id',

        COUNT(*),

        COUNT(
            DISTINCT (
                a.rpt_grp_id,
                a.processing_batch_id
            )
        )

    FROM rule_hit_exclusion_audit a

    JOIN transformation_batches tb
      ON tb.rpt_grp_id = a.rpt_grp_id
     AND tb.batch_id = a.processing_batch_id


    UNION ALL


    /* Candidate 5 */
    SELECT
        'exclusion_audit.reported_batch_id',

        COUNT(*),

        COUNT(
            DISTINCT (
                a.rpt_grp_id,
                a.reported_batch_id
            )
        )

    FROM rule_hit_exclusion_audit a

    JOIN transformation_batches tb
      ON tb.rpt_grp_id = a.rpt_grp_id
     AND tb.batch_id = a.reported_batch_id
)

SELECT jsonb_build_object(

    'query_id', 'VALIDATION_03_BATCH_BRIDGE',

    'period', jsonb_build_object(
        'start_date', '2026-08-01',
        'end_date',   '2026-08-31'
    ),

    'transformation_batch_count',
        (
            SELECT COUNT(*)
            FROM transformation_batches
        ),

    'candidate_bridges',

        COALESCE(
            jsonb_agg(
                jsonb_build_object(

                    'candidate_bridge',
                        candidate_bridge,

                    'matched_rows',
                        matched_rows,

                    'matched_batch_keys',
                        matched_batch_keys

                )
                ORDER BY matched_rows DESC
            ),
            '[]'::jsonb
        )

) AS validation_result

FROM bridge_test;








========================================================================================================================================================================================



WITH params AS (
    SELECT
        DATE '2026-08-01' AS start_date,
        DATE '2026-08-31' AS end_date
),

journey_batches AS (

    SELECT DISTINCT
        rtj.rpt_grp_id,
        rtj.batch_id

    FROM record_transformation_journey rtj
    CROSS JOIN params p

    WHERE rtj.created_timestamp >= p.start_date
      AND rtj.created_timestamp < p.end_date + INTERVAL '1 day'
),

recon_batches AS (

    SELECT DISTINCT
        r.rpt_grp_id,
        r.batch_id

    FROM report_transformation_reconciliation r
    CROSS JOIN params p

    WHERE r.created_timestamp >= p.start_date
      AND r.created_timestamp < p.end_date + INTERVAL '1 day'
),

comparison AS (

    SELECT
        j.rpt_grp_id,
        j.batch_id,

        CASE
            WHEN r.batch_id IS NOT NULL
            THEN TRUE
            ELSE FALSE
        END AS exists_in_reconciliation

    FROM journey_batches j

    LEFT JOIN recon_batches r
      ON r.rpt_grp_id = j.rpt_grp_id
     AND r.batch_id = j.batch_id
)

SELECT jsonb_build_object(

    'query_id',
        'VALIDATION_04_JOURNEY_TO_BATCH_RECON',

    'period',
        jsonb_build_object(
            'start_date', '2026-08-01',
            'end_date', '2026-08-31'
        ),

    'summary',
        jsonb_build_object(

            'journey_batches',
                COUNT(*),

            'journey_batches_with_reconciliation',
                COUNT(*) FILTER (
                    WHERE exists_in_reconciliation
                ),

            'journey_batches_without_reconciliation',
                COUNT(*) FILTER (
                    WHERE NOT exists_in_reconciliation
                )

        ),

    'missing_reconciliation_batches',

        COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'rpt_grp_id', rpt_grp_id,
                    'batch_id', batch_id
                )
            ) FILTER (
                WHERE NOT exists_in_reconciliation
            ),
            '[]'::jsonb
        )

) AS validation_result

FROM comparison;





========================================================================================================================================================================================



WITH params AS (
    SELECT
        DATE '2026-08-01' AS start_date,
        DATE '2026-08-31' AS end_date
),

latest AS (
    SELECT *
    FROM (
        SELECT
            r.*,
            ROW_NUMBER() OVER (
                PARTITION BY r.batch_id, r.rpt_grp_id
                ORDER BY r.seq_no DESC, r.modified_timestamp DESC
            ) AS rn
        FROM report_transformation_reconciliation r
        CROSS JOIN params p
        WHERE r.created_timestamp >= p.start_date
          AND r.created_timestamp < p.end_date + INTERVAL '1 day'
    ) x
    WHERE rn = 1
),

checks AS (
    SELECT
        *,

        COALESCE(txn_selected,0)
        - (
            COALESCE(excluded_txn,0)
          + COALESCE(txn_missing_attempt_count,0)
          + COALESCE(already_reported_count,0)
          + COALESCE(expected_reportable_txn,0)
        ) AS selection_balance_diff

    FROM latest
),

unbalanced AS (
    SELECT *
    FROM checks
    WHERE selection_balance_diff <> 0
)

SELECT jsonb_build_object(

    'query_id', 'VALIDATION_02B_SELECTION_BALANCE_ANALYSIS',

    'period', jsonb_build_object(
        'start_date', '2026-08-01',
        'end_date', '2026-08-31'
    ),

    'summary', jsonb_build_object(
        'unbalanced_batches', COUNT(*),
        'max_selection_difference', MAX(ABS(selection_balance_diff))
    ),

    'candidate_field_totals', jsonb_build_object(
        'txn_simulated', SUM(COALESCE(txn_simulated,0)),
        'lookback_txn', SUM(COALESCE(lookback_txn,0)),
        'lookback_future_reporting_txn', SUM(COALESCE(lookback_future_reporting_txn,0)),
        'lookback_actual_txn', SUM(COALESCE(lookback_actual_txn,0)),
        'reporting_period_txn', SUM(COALESCE(reporting_period_txn,0)),
        'reporting_period_future_reporting_txn', SUM(COALESCE(reporting_period_future_reporting_txn,0)),
        'reporting_period_actual_txn', SUM(COALESCE(reporting_period_actual_txn,0)),
        'activity_selected', SUM(COALESCE(activity_selected,0)),
        'activity_missing', SUM(COALESCE(activity_missing,0)),
        'activity_simulated', SUM(COALESCE(activity_simulated,0))
    ),

    'top_unbalanced_batches',
    COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'batch_id', batch_id,
                'rpt_grp_id', rpt_grp_id,
                'rpt_grp_name', rpt_grp_name,
                'selection_balance_diff', selection_balance_diff,
                'txn_selected', txn_selected,
                'txn_simulated', txn_simulated,
                'excluded_txn', excluded_txn,
                'txn_missing_attempt_count', txn_missing_attempt_count,
                'already_reported_count', already_reported_count,
                'expected_reportable_txn', expected_reportable_txn,
                'lookback_txn', lookback_txn,
                'lookback_future_reporting_txn', lookback_future_reporting_txn,
                'lookback_actual_txn', lookback_actual_txn,
                'reporting_period_txn', reporting_period_txn,
                'reporting_period_future_reporting_txn', reporting_period_future_reporting_txn,
                'reporting_period_actual_txn', reporting_period_actual_txn,
                'activity_selected', activity_selected,
                'activity_missing', activity_missing,
                'activity_simulated', activity_simulated
            )
            ORDER BY ABS(selection_balance_diff) DESC
        ),
        '[]'::jsonb
    )

) AS validation_result

FROM (
    SELECT *
    FROM unbalanced
    ORDER BY ABS(selection_balance_diff) DESC
    LIMIT 50
) x;




=======================================================================================================================================================================

WITH params AS (
    SELECT
        DATE '2026-08-01' AS start_date,
        DATE '2026-08-31' AS end_date
),

latest AS (
    SELECT *
    FROM (
        SELECT
            r.*,
            ROW_NUMBER() OVER (
                PARTITION BY r.batch_id, r.rpt_grp_id
                ORDER BY r.seq_no DESC, r.modified_timestamp DESC
            ) AS rn
        FROM report_transformation_reconciliation r
        CROSS JOIN params p
        WHERE r.created_timestamp >= p.start_date
          AND r.created_timestamp < p.end_date + INTERVAL '1 day'
    ) x
    WHERE rn = 1
),

checks AS (
    SELECT
        *,

        /* A — expected reportable vs activity selected */
        COALESCE(expected_reportable_txn,0)
        - COALESCE(activity_selected,0)
            AS expected_vs_activity_selected_diff,

        /* B — activity-selected composition */
        COALESCE(activity_selected,0)
        - (
            COALESCE(lookback_txn,0)
          + COALESCE(reporting_period_txn,0)
          + COALESCE(activity_simulated,0)
        ) AS activity_selected_balance_diff,

        /* C — lookback composition */
        COALESCE(lookback_txn,0)
        - (
            COALESCE(lookback_actual_txn,0)
          + COALESCE(lookback_future_reporting_txn,0)
        ) AS lookback_balance_diff,

        /* D — reporting-period composition */
        COALESCE(reporting_period_txn,0)
        - (
            COALESCE(reporting_period_actual_txn,0)
          + COALESCE(reporting_period_future_reporting_txn,0)
        ) AS reporting_period_balance_diff,

        /* E — transformation disposition */
        COALESCE(actual_activity_eligible_for_transformation,0)
        - (
            COALESCE(activity_transformed,0)
          + COALESCE(activity_transformation_failed,0)
          + COALESCE(duplicate_transformation,0)
        ) AS transformation_balance_diff

    FROM latest
)

SELECT jsonb_build_object(

    'query_id',
        'VALIDATION_02C_CONTROL_RELATIONSHIPS',

    'period',
        jsonb_build_object(
            'start_date', '2026-08-01',
            'end_date',   '2026-08-31'
        ),

    'summary',
        jsonb_build_object(

            'total_batches',
                COUNT(*),

            'expected_equals_activity_selected',
                COUNT(*) FILTER (
                    WHERE expected_vs_activity_selected_diff = 0
                ),

            'expected_not_equal_activity_selected',
                COUNT(*) FILTER (
                    WHERE expected_vs_activity_selected_diff <> 0
                ),

            'activity_selected_balanced',
                COUNT(*) FILTER (
                    WHERE activity_selected_balance_diff = 0
                ),

            'activity_selected_unbalanced',
                COUNT(*) FILTER (
                    WHERE activity_selected_balance_diff <> 0
                ),

            'lookback_balanced',
                COUNT(*) FILTER (
                    WHERE lookback_balance_diff = 0
                ),

            'lookback_unbalanced',
                COUNT(*) FILTER (
                    WHERE lookback_balance_diff <> 0
                ),

            'reporting_period_balanced',
                COUNT(*) FILTER (
                    WHERE reporting_period_balance_diff = 0
                ),

            'reporting_period_unbalanced',
                COUNT(*) FILTER (
                    WHERE reporting_period_balance_diff <> 0
                ),

            'transformation_balanced',
                COUNT(*) FILTER (
                    WHERE transformation_balance_diff = 0
                ),

            'transformation_unbalanced',
                COUNT(*) FILTER (
                    WHERE transformation_balance_diff <> 0
                )
        ),

    'max_variances',
        jsonb_build_object(

            'expected_vs_activity_selected',
                MAX(ABS(expected_vs_activity_selected_diff)),

            'activity_selected',
                MAX(ABS(activity_selected_balance_diff)),

            'lookback',
                MAX(ABS(lookback_balance_diff)),

            'reporting_period',
                MAX(ABS(reporting_period_balance_diff)),

            'transformation',
                MAX(ABS(transformation_balance_diff))
        ),

    'sample_exceptions',
        COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'batch_id', batch_id,
                    'rpt_grp_id', rpt_grp_id,
                    'rpt_grp_name', rpt_grp_name,

                    'expected_reportable_txn',
                        expected_reportable_txn,

                    'activity_selected',
                        activity_selected,

                    'expected_vs_activity_selected_diff',
                        expected_vs_activity_selected_diff,

                    'lookback_txn',
                        lookback_txn,

                    'reporting_period_txn',
                        reporting_period_txn,

                    'activity_selected_balance_diff',
                        activity_selected_balance_diff,

                    'lookback_balance_diff',
                        lookback_balance_diff,

                    'reporting_period_balance_diff',
                        reporting_period_balance_diff,

                    'transformation_balance_diff',
                        transformation_balance_diff
                )
                ORDER BY
                    ABS(activity_selected_balance_diff) DESC,
                    ABS(expected_vs_activity_selected_diff) DESC
            ) FILTER (
                WHERE expected_vs_activity_selected_diff <> 0
                   OR activity_selected_balance_diff <> 0
                   OR lookback_balance_diff <> 0
                   OR reporting_period_balance_diff <> 0
                   OR transformation_balance_diff <> 0
            ),
            '[]'::jsonb
        )

) AS validation_result

FROM checks;


===============================================================================


WITH params AS (
    SELECT
        DATE '2026-08-01' AS start_date,
        DATE '2026-08-31' AS end_date
),

transformation_batches AS (
    SELECT DISTINCT
        r.rpt_grp_id,
        r.batch_id
    FROM report_transformation_reconciliation r
    CROSS JOIN params p
    WHERE r.batch_id IS NOT NULL
      AND r.created_timestamp >= p.start_date
      AND r.created_timestamp < p.end_date + INTERVAL '1 day'
),

bridge_test AS (

    SELECT
        'rule_hit.batch_id' AS candidate_bridge,
        COUNT(*) AS matched_rows,
        COUNT(
            DISTINCT (rh.rpt_grp_id, rh.batch_id)
        ) AS matched_batch_keys
    FROM rule_hit rh
    JOIN transformation_batches tb
      ON tb.rpt_grp_id = rh.rpt_grp_id
     AND tb.batch_id = rh.batch_id::text

    UNION ALL

    SELECT
        'rule_hit.efile_batch_id',
        COUNT(*),
        COUNT(
            DISTINCT (rh.rpt_grp_id, rh.efile_batch_id)
        )
    FROM rule_hit rh
    JOIN transformation_batches tb
      ON tb.rpt_grp_id = rh.rpt_grp_id
     AND tb.batch_id = rh.efile_batch_id

    UNION ALL

    SELECT
        'rule_hit.reported_batch_id',
        COUNT(*),
        COUNT(
            DISTINCT (rh.rpt_grp_id, rh.reported_batch_id)
        )
    FROM rule_hit rh
    JOIN transformation_batches tb
      ON tb.rpt_grp_id = rh.rpt_grp_id
     AND tb.batch_id = rh.reported_batch_id

    UNION ALL

    SELECT
        'exclusion_audit.processing_batch_id',
        COUNT(*),
        COUNT(
            DISTINCT (a.rpt_grp_id, a.processing_batch_id)
        )
    FROM rule_hit_exclusion_audit a
    JOIN transformation_batches tb
      ON tb.rpt_grp_id = a.rpt_grp_id
     AND tb.batch_id = a.processing_batch_id

    UNION ALL

    SELECT
        'exclusion_audit.reported_batch_id',
        COUNT(*),
        COUNT(
            DISTINCT (a.rpt_grp_id, a.reported_batch_id)
        )
    FROM rule_hit_exclusion_audit a
    JOIN transformation_batches tb
      ON tb.rpt_grp_id = a.rpt_grp_id
     AND tb.batch_id = a.reported_batch_id
)

SELECT jsonb_build_object(

    'query_id',
        'VALIDATION_03_BATCH_BRIDGE',

    'period',
        jsonb_build_object(
            'start_date', '2026-08-01',
            'end_date', '2026-08-31'
        ),

    'transformation_batch_count',
        (
            SELECT COUNT(*)
            FROM transformation_batches
        ),

    'candidate_bridges',
        jsonb_agg(
            jsonb_build_object(
                'candidate_bridge', candidate_bridge,
                'matched_rows', matched_rows,
                'matched_batch_keys', matched_batch_keys
            )
            ORDER BY matched_rows DESC
        )

) AS validation_result

FROM bridge_test;


==========================================================================

WITH params AS (
    SELECT
        DATE '2026-08-01' AS start_date,
        DATE '2026-08-31' AS end_date
),

transformation_batches AS (
    SELECT DISTINCT
        r.rpt_grp_id,
        r.rpt_grp_name,
        r.batch_id
    FROM report_transformation_reconciliation r
    CROSS JOIN params p
    WHERE r.created_timestamp >= p.start_date
      AND r.created_timestamp < p.end_date + INTERVAL '1 day'
      AND r.batch_id IS NOT NULL
),

efile_matches AS (
    SELECT
        tb.rpt_grp_id,
        tb.rpt_grp_name,
        tb.batch_id,

        COUNT(rh.*) AS rule_hit_rows,
        COUNT(DISTINCT rh.rule_id) AS distinct_rules,
        COUNT(DISTINCT rh.mtcn) AS distinct_mtcns

    FROM transformation_batches tb

    LEFT JOIN rule_hit rh
      ON rh.rpt_grp_id = tb.rpt_grp_id
     AND rh.efile_batch_id = tb.batch_id

    GROUP BY
        tb.rpt_grp_id,
        tb.rpt_grp_name,
        tb.batch_id
),

audit_matches AS (
    SELECT
        tb.rpt_grp_id,
        tb.batch_id,

        COUNT(a.*) AS exclusion_rows

    FROM transformation_batches tb

    LEFT JOIN rule_hit_exclusion_audit a
      ON a.rpt_grp_id = tb.rpt_grp_id
     AND a.processing_batch_id = tb.batch_id

    GROUP BY
        tb.rpt_grp_id,
        tb.batch_id
),

combined AS (
    SELECT
        e.rpt_grp_id,
        e.rpt_grp_name,
        e.batch_id,

        e.rule_hit_rows,
        e.distinct_rules,
        e.distinct_mtcns,

        COALESCE(a.exclusion_rows, 0) AS exclusion_rows

    FROM efile_matches e

    LEFT JOIN audit_matches a
      ON a.rpt_grp_id = e.rpt_grp_id
     AND a.batch_id = e.batch_id
),

report_group_summary AS (
    SELECT
        rpt_grp_id,
        rpt_grp_name,

        COUNT(*) AS transformation_batches,

        COUNT(*) FILTER (
            WHERE rule_hit_rows > 0
        ) AS batches_with_rule_hits,

        COUNT(*) FILTER (
            WHERE exclusion_rows > 0
        ) AS batches_with_exclusions,

        SUM(rule_hit_rows) AS total_rule_hit_rows,
        SUM(distinct_rules) AS total_distinct_rules,
        SUM(distinct_mtcns) AS total_distinct_mtcns,
        SUM(exclusion_rows) AS total_exclusion_rows

    FROM combined

    GROUP BY
        rpt_grp_id,
        rpt_grp_name
)

SELECT jsonb_build_object(

    'query_id',
        'VALIDATION_03B_BATCH_BRIDGE_BY_REPORT_GROUP',

    'period',
        jsonb_build_object(
            'start_date', '2026-08-01',
            'end_date', '2026-08-31'
        ),

    'summary',
        jsonb_build_object(

            'transformation_batches',
                (SELECT COUNT(*) FROM combined),

            'batches_with_rule_hit_efile_match',
                (
                    SELECT COUNT(*)
                    FROM combined
                    WHERE rule_hit_rows > 0
                ),

            'batches_with_exclusion_processing_match',
                (
                    SELECT COUNT(*)
                    FROM combined
                    WHERE exclusion_rows > 0
                ),

            'batches_with_both',
                (
                    SELECT COUNT(*)
                    FROM combined
                    WHERE rule_hit_rows > 0
                      AND exclusion_rows > 0
                )
        ),

    'report_groups',
        COALESCE(
            (
                SELECT jsonb_agg(
                    jsonb_build_object(

                        'rpt_grp_id',
                            rpt_grp_id,

                        'rpt_grp_name',
                            rpt_grp_name,

                        'transformation_batches',
                            transformation_batches,

                        'batches_with_rule_hits',
                            batches_with_rule_hits,

                        'batches_with_exclusions',
                            batches_with_exclusions,

                        'total_rule_hit_rows',
                            total_rule_hit_rows,

                        'total_distinct_rules',
                            total_distinct_rules,

                        'total_distinct_mtcns',
                            total_distinct_mtcns,

                        'total_exclusion_rows',
                            total_exclusion_rows

                    )
                    ORDER BY batches_with_rule_hits DESC
                )
                FROM report_group_summary
            ),
            '[]'::jsonb
        ),

    'matched_batch_samples',
        COALESCE(
            (
                SELECT jsonb_agg(
                    jsonb_build_object(

                        'rpt_grp_id',
                            rpt_grp_id,

                        'rpt_grp_name',
                            rpt_grp_name,

                        'batch_id',
                            batch_id,

                        'rule_hit_rows',
                            rule_hit_rows,

                        'distinct_rules',
                            distinct_rules,

                        'distinct_mtcns',
                            distinct_mtcns,

                        'exclusion_rows',
                            exclusion_rows
                    )
                    ORDER BY rule_hit_rows DESC
                )

                FROM (
                    SELECT *
                    FROM combined
                    WHERE rule_hit_rows > 0
                       OR exclusion_rows > 0
                    ORDER BY rule_hit_rows DESC
                    LIMIT 50
                ) x
            ),
            '[]'::jsonb
        )

) AS validation_result;

===========================================================================================================


WITH params AS (
    SELECT
        DATE '2026-08-01' AS start_date,
        DATE '2026-08-31' AS end_date
),

/* August transformation batches */
batches AS (
    SELECT DISTINCT
        rpt_grp_id,
        batch_id
    FROM report_transformation_reconciliation r
    CROSS JOIN params p
    WHERE r.created_timestamp >= p.start_date
      AND r.created_timestamp < p.end_date + INTERVAL '1 day'
),

/*
 One logical transaction per batch.
 Journey has multiple stage rows for the same transaction.
*/
journey_txns AS (
    SELECT DISTINCT
        j.rpt_grp_id,
        j.batch_id,
        j.identifier,
        j.mtcn,
        j.txn_metadata ->> 'txn_sur_key' AS txn_sur_key
    FROM record_transformation_journey j
    JOIN batches b
      ON b.rpt_grp_id = j.rpt_grp_id
     AND b.batch_id = j.batch_id
),

/*
 Rule hits linked to transformation batches using the
 batch bridge we already validated.
*/
rule_hits AS (
    SELECT
        rh.rpt_grp_id,
        rh.efile_batch_id,
        rh.rule_id,
        rh.attempt_id,
        rh.external_txn_key,
        rh.mtcn,
        rh.galactic_id,
        rh.is_reported,
        rh.exclusion_reason_id
    FROM rule_hit rh
    JOIN batches b
      ON b.rpt_grp_id = rh.rpt_grp_id
     AND b.batch_id = rh.efile_batch_id
),

/* Candidate 1: txn_sur_key -> external_txn_key */
txn_sur_key_match AS (
    SELECT
        j.rpt_grp_id,
        j.batch_id,
        j.identifier,
        COUNT(DISTINCT rh.external_txn_key) AS external_keys_found
    FROM journey_txns j
    JOIN rule_hits rh
      ON rh.rpt_grp_id = j.rpt_grp_id
     AND rh.efile_batch_id = j.batch_id
     AND rh.external_txn_key::text = j.txn_sur_key
    GROUP BY
        j.rpt_grp_id,
        j.batch_id,
        j.identifier
),

/* Candidate 2: MTCN -> MTCN */
mtcn_match AS (
    SELECT
        j.rpt_grp_id,
        j.batch_id,
        j.identifier,
        COUNT(DISTINCT rh.external_txn_key) AS external_keys_found
    FROM journey_txns j
    JOIN rule_hits rh
      ON rh.rpt_grp_id = j.rpt_grp_id
     AND rh.efile_batch_id = j.batch_id
     AND rh.mtcn = j.mtcn
    WHERE j.mtcn IS NOT NULL
    GROUP BY
        j.rpt_grp_id,
        j.batch_id,
        j.identifier
),

/* Candidate 3: identifier -> external_txn_key */
identifier_external_match AS (
    SELECT
        j.rpt_grp_id,
        j.batch_id,
        j.identifier,
        COUNT(DISTINCT rh.external_txn_key) AS external_keys_found
    FROM journey_txns j
    JOIN rule_hits rh
      ON rh.rpt_grp_id = j.rpt_grp_id
     AND rh.efile_batch_id = j.batch_id
     AND rh.external_txn_key::text = j.identifier
    GROUP BY
        j.rpt_grp_id,
        j.batch_id,
        j.identifier
),

summary AS (
    SELECT
        'txn_metadata.txn_sur_key -> rule_hit.external_txn_key' AS candidate,
        COUNT(*) AS matched_transactions,
        COUNT(*) FILTER (WHERE external_keys_found = 1)
            AS uniquely_matched_transactions,
        COUNT(*) FILTER (WHERE external_keys_found > 1)
            AS ambiguous_transactions
    FROM txn_sur_key_match

    UNION ALL

    SELECT
        'journey.mtcn -> rule_hit.mtcn',
        COUNT(*),
        COUNT(*) FILTER (WHERE external_keys_found = 1),
        COUNT(*) FILTER (WHERE external_keys_found > 1)
    FROM mtcn_match

    UNION ALL

    SELECT
        'journey.identifier -> rule_hit.external_txn_key',
        COUNT(*),
        COUNT(*) FILTER (WHERE external_keys_found = 1),
        COUNT(*) FILTER (WHERE external_keys_found > 1)
    FROM identifier_external_match
)

SELECT jsonb_build_object(

    'query_id',
        'VALIDATION_04_TRANSACTION_BRIDGE',

    'period',
        jsonb_build_object(
            'start_date', '2026-08-01',
            'end_date', '2026-08-31'
        ),

    'total_journey_transactions',
        (SELECT COUNT(*) FROM journey_txns),

    'journey_transactions_with_txn_sur_key',
        (
            SELECT COUNT(*)
            FROM journey_txns
            WHERE txn_sur_key IS NOT NULL
        ),

    'journey_transactions_with_mtcn',
        (
            SELECT COUNT(*)
            FROM journey_txns
            WHERE mtcn IS NOT NULL
        ),

    'candidate_transaction_bridges',
        (
            SELECT jsonb_agg(
                jsonb_build_object(
                    'candidate', candidate,
                    'matched_transactions', matched_transactions,
                    'uniquely_matched_transactions',
                        uniquely_matched_transactions,
                    'ambiguous_transactions',
                        ambiguous_transactions
                )
                ORDER BY matched_transactions DESC
            )
            FROM summary
        )

) AS validation_result;





===============================================================================================================================================================

WITH latest_recon AS (
    SELECT *
    FROM (
        SELECT
            r.*,
            ROW_NUMBER() OVER (
                PARTITION BY r.rpt_grp_id, r.run_date
                ORDER BY r.seq_no DESC, r.modified_timestamp DESC
            ) AS rn
        FROM rule_hit_reconciliation r
        WHERE r.run_date BETWEEN 20260801 AND 20260831
    ) x
    WHERE rn = 1
),

detail AS (
    SELECT
        lr.rpt_grp_id,
        lr.rpt_grp_name,
        lr.run_date,
        lr.seq_no,

        lr.data_selection_start_date,
        lr.data_selection_end_date,

        COALESCE(lr.distinct_rule_hits_count_iwra, 0)
            AS reconciliation_expected,

        COALESCE(lr.distinct_rule_hits_count_pharos, 0)
            AS reconciliation_matched,

        COALESCE(lr.missed_rule_hits_count_pharos, 0)
            AS reconciliation_missed,

        COUNT(rh.*)
            AS rule_hit_rows,

        /*
         * Candidate grain:
         * distinct transaction/rule combination
         */
        COUNT(
            DISTINCT (
                rh.external_txn_key,
                rh.rule_id
            )
        ) AS distinct_rule_hit_keys,

        /*
         * Candidate A:
         * explicitly is_reported = FALSE
         */
        COUNT(
            DISTINCT (
                rh.external_txn_key,
                rh.rule_id
            )
        ) FILTER (
            WHERE rh.exclusion_reason_id IS NULL
              AND rh.is_reported = FALSE
        ) AS missed_is_reported_false,

        /*
         * Candidate B:
         * anything not TRUE, including NULL
         */
        COUNT(
            DISTINCT (
                rh.external_txn_key,
                rh.rule_id
            )
        ) FILTER (
            WHERE rh.exclusion_reason_id IS NULL
              AND rh.is_reported IS NOT TRUE
        ) AS missed_is_reported_not_true,

        /*
         * Candidate C:
         * no reporting timestamp
         */
        COUNT(
            DISTINCT (
                rh.external_txn_key,
                rh.rule_id
            )
        ) FILTER (
            WHERE rh.exclusion_reason_id IS NULL
              AND rh.reporting_timestamp IS NULL
        ) AS missed_reporting_timestamp_null,

        /*
         * Candidate D:
         * no reported batch
         */
        COUNT(
            DISTINCT (
                rh.external_txn_key,
                rh.rule_id
            )
        ) FILTER (
            WHERE rh.exclusion_reason_id IS NULL
              AND rh.reported_batch_id IS NULL
        ) AS missed_reported_batch_null,

        /*
         * Candidate matched definition:
         * explicitly reported = TRUE
         */
        COUNT(
            DISTINCT (
                rh.external_txn_key,
                rh.rule_id
            )
        ) FILTER (
            WHERE rh.exclusion_reason_id IS NULL
              AND rh.is_reported = TRUE
        ) AS matched_is_reported_true_nonexcluded,

        /*
         * Test reported=true regardless of exclusion
         * because we've seen reported+excluded rows.
         */
        COUNT(
            DISTINCT (
                rh.external_txn_key,
                rh.rule_id
            )
        ) FILTER (
            WHERE rh.is_reported = TRUE
        ) AS matched_is_reported_true_all,

        COUNT(
            DISTINCT (
                rh.external_txn_key,
                rh.rule_id
            )
        ) FILTER (
            WHERE rh.reporting_timestamp IS NOT NULL
        ) AS matched_reporting_timestamp_present

    FROM latest_recon lr

    LEFT JOIN rule_hit rh
      ON rh.rpt_grp_id = lr.rpt_grp_id

     /*
      * Use the reconciliation business-selection window,
      * not the reconciliation creation timestamp.
      */
     AND rh.transaction_date >= lr.data_selection_start_date
     AND rh.transaction_date <= lr.data_selection_end_date

    GROUP BY
        lr.rpt_grp_id,
        lr.rpt_grp_name,
        lr.run_date,
        lr.seq_no,
        lr.data_selection_start_date,
        lr.data_selection_end_date,
        lr.distinct_rule_hits_count_iwra,
        lr.distinct_rule_hits_count_pharos,
        lr.missed_rule_hits_count_pharos
),

scored AS (
    SELECT
        *,

        missed_is_reported_false
            - reconciliation_missed
            AS variance_missed_false,

        missed_is_reported_not_true
            - reconciliation_missed
            AS variance_missed_not_true,

        missed_reporting_timestamp_null
            - reconciliation_missed
            AS variance_missed_timestamp_null,

        missed_reported_batch_null
            - reconciliation_missed
            AS variance_missed_reported_batch_null,

        matched_is_reported_true_nonexcluded
            - reconciliation_matched
            AS variance_matched_true_nonexcluded,

        matched_is_reported_true_all
            - reconciliation_matched
            AS variance_matched_true_all,

        matched_reporting_timestamp_present
            - reconciliation_matched
            AS variance_matched_timestamp_present

    FROM detail
)

SELECT jsonb_build_object(

    'query_id',
        'VALIDATION_05_RULE_HIT_DETAIL_DEFINITION',

    'period',
        jsonb_build_object(
            'start_date', '2026-08-01',
            'end_date', '2026-08-31'
        ),

    'summary',
        jsonb_build_object(

            'reconciliation_populations',
                COUNT(*),

            'missed_false_exact_matches',
                COUNT(*) FILTER (
                    WHERE variance_missed_false = 0
                ),

            'missed_not_true_exact_matches',
                COUNT(*) FILTER (
                    WHERE variance_missed_not_true = 0
                ),

            'missed_timestamp_null_exact_matches',
                COUNT(*) FILTER (
                    WHERE variance_missed_timestamp_null = 0
                ),

            'missed_reported_batch_null_exact_matches',
                COUNT(*) FILTER (
                    WHERE variance_missed_reported_batch_null = 0
                ),

            'matched_true_nonexcluded_exact_matches',
                COUNT(*) FILTER (
                    WHERE variance_matched_true_nonexcluded = 0
                ),

            'matched_true_all_exact_matches',
                COUNT(*) FILTER (
                    WHERE variance_matched_true_all = 0
                ),

            'matched_timestamp_present_exact_matches',
                COUNT(*) FILTER (
                    WHERE variance_matched_timestamp_present = 0
                )
        ),

    'rows',
        COALESCE(
            jsonb_agg(
                jsonb_build_object(

                    'rpt_grp_id',
                        rpt_grp_id,

                    'rpt_grp_name',
                        rpt_grp_name,

                    'run_date',
                        run_date,

                    'reconciliation_expected',
                        reconciliation_expected,

                    'reconciliation_matched',
                        reconciliation_matched,

                    'reconciliation_missed',
                        reconciliation_missed,

                    'rule_hit_rows',
                        rule_hit_rows,

                    'distinct_rule_hit_keys',
                        distinct_rule_hit_keys,

                    'candidate_missed_counts',
                        jsonb_build_object(

                            'is_reported_false',
                                missed_is_reported_false,

                            'is_reported_not_true',
                                missed_is_reported_not_true,

                            'reporting_timestamp_null',
                                missed_reporting_timestamp_null,

                            'reported_batch_null',
                                missed_reported_batch_null
                        ),

                    'candidate_matched_counts',
                        jsonb_build_object(

                            'is_reported_true_nonexcluded',
                                matched_is_reported_true_nonexcluded,

                            'is_reported_true_all',
                                matched_is_reported_true_all,

                            'reporting_timestamp_present',
                                matched_reporting_timestamp_present
                        ),

                    'variances',
                        jsonb_build_object(

                            'missed_false',
                                variance_missed_false,

                            'missed_not_true',
                                variance_missed_not_true,

                            'missed_timestamp_null',
                                variance_missed_timestamp_null,

                            'missed_reported_batch_null',
                                variance_missed_reported_batch_null,

                            'matched_true_nonexcluded',
                                variance_matched_true_nonexcluded,

                            'matched_true_all',
                                variance_matched_true_all,

                            'matched_timestamp_present',
                                variance_matched_timestamp_present
                        )
                )
                ORDER BY rpt_grp_name, run_date
            ),
            '[]'::jsonb
        )

) AS validation_result

FROM scored;

=================================================================================================================================

WITH params AS (
    SELECT
        DATE '2026-08-01' AS start_date,
        DATE '2026-08-31' AS end_date
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
        WHERE r.created_timestamp >= p.start_date
          AND r.created_timestamp < p.end_date + INTERVAL '1 day'
    ) x
    WHERE rn = 1
),

detail AS (
    SELECT
        lr.rpt_grp_id,
        lr.rpt_grp_name,
        lr.run_date,
        lr.seq_no,
        lr.created_timestamp,
        lr.data_selection_start_date,
        lr.data_selection_end_date,

        COALESCE(lr.distinct_rule_hits_count_iwra,0)
            AS reconciliation_expected,

        COALESCE(lr.distinct_rule_hits_count_pharos,0)
            AS reconciliation_matched,

        COALESCE(lr.missed_rule_hits_count_pharos,0)
            AS reconciliation_missed,

        COUNT(rh.*) AS rule_hit_rows,

        COUNT(
            DISTINCT (
                rh.external_txn_key,
                rh.rule_id
            )
        ) AS distinct_rule_hit_keys,

        COUNT(
            DISTINCT (
                rh.external_txn_key,
                rh.rule_id
            )
        ) FILTER (
            WHERE rh.exclusion_reason_id IS NULL
              AND rh.is_reported = FALSE
        ) AS missed_is_reported_false,

        COUNT(
            DISTINCT (
                rh.external_txn_key,
                rh.rule_id
            )
        ) FILTER (
            WHERE rh.exclusion_reason_id IS NULL
              AND rh.is_reported IS NOT TRUE
        ) AS missed_is_reported_not_true,

        COUNT(
            DISTINCT (
                rh.external_txn_key,
                rh.rule_id
            )
        ) FILTER (
            WHERE rh.exclusion_reason_id IS NULL
              AND rh.reporting_timestamp IS NULL
        ) AS missed_reporting_timestamp_null,

        COUNT(
            DISTINCT (
                rh.external_txn_key,
                rh.rule_id
            )
        ) FILTER (
            WHERE rh.exclusion_reason_id IS NULL
              AND rh.reported_batch_id IS NULL
        ) AS missed_reported_batch_null,

        COUNT(
            DISTINCT (
                rh.external_txn_key,
                rh.rule_id
            )
        ) FILTER (
            WHERE rh.exclusion_reason_id IS NULL
              AND rh.is_reported = TRUE
        ) AS matched_true_nonexcluded,

        COUNT(
            DISTINCT (
                rh.external_txn_key,
                rh.rule_id
            )
        ) FILTER (
            WHERE rh.is_reported = TRUE
        ) AS matched_true_all,

        COUNT(
            DISTINCT (
                rh.external_txn_key,
                rh.rule_id
            )
        ) FILTER (
            WHERE rh.reporting_timestamp IS NOT NULL
        ) AS matched_timestamp_present

    FROM latest_recon lr

    LEFT JOIN rule_hit rh
      ON rh.rpt_grp_id = lr.rpt_grp_id
     AND rh.transaction_date >= lr.data_selection_start_date
     AND rh.transaction_date <= lr.data_selection_end_date

    GROUP BY
        lr.rpt_grp_id,
        lr.rpt_grp_name,
        lr.run_date,
        lr.seq_no,
        lr.created_timestamp,
        lr.data_selection_start_date,
        lr.data_selection_end_date,
        lr.distinct_rule_hits_count_iwra,
        lr.distinct_rule_hits_count_pharos,
        lr.missed_rule_hits_count_pharos
),

scored AS (
    SELECT
        *,

        missed_is_reported_false
            - reconciliation_missed
            AS variance_missed_false,

        missed_is_reported_not_true
            - reconciliation_missed
            AS variance_missed_not_true,

        missed_reporting_timestamp_null
            - reconciliation_missed
            AS variance_missed_timestamp_null,

        missed_reported_batch_null
            - reconciliation_missed
            AS variance_missed_reported_batch_null,

        matched_true_nonexcluded
            - reconciliation_matched
            AS variance_matched_true_nonexcluded,

        matched_true_all
            - reconciliation_matched
            AS variance_matched_true_all,

        matched_timestamp_present
            - reconciliation_matched
            AS variance_matched_timestamp_present

    FROM detail
)

SELECT jsonb_build_object(

    'query_id',
        'VALIDATION_05B_RULE_HIT_DETAIL_DEFINITION',

    'period',
        jsonb_build_object(
            'start_date', '2026-08-01',
            'end_date', '2026-08-31'
        ),

    'summary',
        jsonb_build_object(

            'reconciliation_populations',
                COUNT(*),

            'missed_false_exact_matches',
                COUNT(*) FILTER (
                    WHERE variance_missed_false = 0
                ),

            'missed_not_true_exact_matches',
                COUNT(*) FILTER (
                    WHERE variance_missed_not_true = 0
                ),

            'missed_timestamp_null_exact_matches',
                COUNT(*) FILTER (
                    WHERE variance_missed_timestamp_null = 0
                ),

            'missed_reported_batch_null_exact_matches',
                COUNT(*) FILTER (
                    WHERE variance_missed_reported_batch_null = 0
                ),

            'matched_true_nonexcluded_exact_matches',
                COUNT(*) FILTER (
                    WHERE variance_matched_true_nonexcluded = 0
                ),

            'matched_true_all_exact_matches',
                COUNT(*) FILTER (
                    WHERE variance_matched_true_all = 0
                ),

            'matched_timestamp_present_exact_matches',
                COUNT(*) FILTER (
                    WHERE variance_matched_timestamp_present = 0
                )
        ),

    'rows',
        COALESCE(
            jsonb_agg(
                jsonb_build_object(

                    'rpt_grp_id', rpt_grp_id,
                    'rpt_grp_name', rpt_grp_name,
                    'run_date', run_date,
                    'created_timestamp', created_timestamp,

                    'data_selection_start_date',
                        data_selection_start_date,

                    'data_selection_end_date',
                        data_selection_end_date,

                    'reconciliation_expected',
                        reconciliation_expected,

                    'reconciliation_matched',
                        reconciliation_matched,

                    'reconciliation_missed',
                        reconciliation_missed,

                    'rule_hit_rows',
                        rule_hit_rows,

                    'distinct_rule_hit_keys',
                        distinct_rule_hit_keys,

                    'candidate_missed_counts',
                        jsonb_build_object(
                            'is_reported_false',
                                missed_is_reported_false,
                            'is_reported_not_true',
                                missed_is_reported_not_true,
                            'reporting_timestamp_null',
                                missed_reporting_timestamp_null,
                            'reported_batch_null',
                                missed_reported_batch_null
                        ),

                    'candidate_matched_counts',
                        jsonb_build_object(
                            'is_reported_true_nonexcluded',
                                matched_true_nonexcluded,
                            'is_reported_true_all',
                                matched_true_all,
                            'reporting_timestamp_present',
                                matched_timestamp_present
                        ),

                    'variances',
                        jsonb_build_object(
                            'missed_false',
                                variance_missed_false,
                            'missed_not_true',
                                variance_missed_not_true,
                            'missed_timestamp_null',
                                variance_missed_timestamp_null,
                            'missed_reported_batch_null',
                                variance_missed_reported_batch_null,
                            'matched_true_nonexcluded',
                                variance_matched_true_nonexcluded,
                            'matched_true_all',
                                variance_matched_true_all,
                            'matched_timestamp_present',
                                variance_matched_timestamp_present
                        )
                )
                ORDER BY rpt_grp_name, created_timestamp
            ),
            '[]'::jsonb
        )

) AS validation_result

FROM scored;
