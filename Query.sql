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
