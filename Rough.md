```sql
WITH params AS (
    SELECT
        TIMESTAMPTZ '2026-06-01 00:00:00+00' AS from_ts,
        TIMESTAMPTZ '2026-07-01 00:00:00+00' AS to_ts
),
latest_batch_run AS (
    SELECT *
    FROM (
        SELECT
            r.*,
            ROW_NUMBER() OVER (
                PARTITION BY r.rpt_grp_id, r.batch_id
                ORDER BY r.seq_no DESC, r.modified_timestamp DESC
            ) AS rn
        FROM pharos.report_transformation_reconciliation r
        CROSS JOIN params p
        WHERE r.created_timestamp >= p.from_ts
          AND r.created_timestamp < p.to_ts
    ) x
    WHERE rn = 1
),
report_generation_counts AS (
    SELECT
        j.rpt_grp_id,
        j.batch_id,
        COUNT(DISTINCT j.identifier) AS report_generation_transactions
    FROM pharos.record_transformation_journey j
    WHERE j.stage = 'REPORT_GENERATION'
      AND j.status = 'GENERATED'
    GROUP BY j.rpt_grp_id, j.batch_id
),
joined AS (
    SELECT
        b.rpt_grp_id,
        b.rpt_grp_name,
        b.batch_id,
        b.seq_no,
        COALESCE(b.actual_reportable_txn, 0) AS actual_reportable_txn,
        COALESCE(g.report_generation_transactions, 0) AS report_generation_transactions,
        COALESCE(g.report_generation_transactions, 0) - COALESCE(b.actual_reportable_txn, 0)
            AS report_generation_minus_actual_reportable,
        bi.report_status,
        bi.compiler_status,
        bi.batch_status
    FROM latest_batch_run b
    LEFT JOIN report_generation_counts g
      ON g.rpt_grp_id = b.rpt_grp_id
     AND g.batch_id = b.batch_id
    LEFT JOIN pharos.report_batch_info bi
      ON bi.rpt_grp_id = b.rpt_grp_id
     AND bi.batch_id = b.batch_id
     AND bi.seq_no = b.seq_no
)
SELECT jsonb_build_object(
    'query_id', 'VAL_16_REPORT_GENERATION_VALIDATION',

    'total_batches', COUNT(*),

    'batches_with_report_generation_evidence',
        COUNT(*) FILTER (WHERE report_generation_transactions > 0),

    'batches_with_actual_reportable_txn',
        COUNT(*) FILTER (WHERE actual_reportable_txn > 0),

    'exact_match_batches',
        COUNT(*) FILTER (WHERE report_generation_transactions = actual_reportable_txn),

    'report_generation_less_than_actual_reportable',
        COUNT(*) FILTER (WHERE report_generation_transactions < actual_reportable_txn),

    'report_generation_greater_than_actual_reportable',
        COUNT(*) FILTER (WHERE report_generation_transactions > actual_reportable_txn),

    'sum_actual_reportable_txn', SUM(actual_reportable_txn),
    'sum_report_generation_transactions', SUM(report_generation_transactions),

    'report_generation_by_compiler_status',
        (
            SELECT COALESCE(jsonb_object_agg(status_value, cnt), '{}'::jsonb)
            FROM (
                SELECT
                    COALESCE(compiler_status, '<NULL>') AS status_value,
                    SUM(report_generation_transactions) AS cnt
                FROM joined
                GROUP BY COALESCE(compiler_status, '<NULL>')
            ) x
        ),

    'batches_compiler_completed_with_zero_report_generation',
        COUNT(*) FILTER (
            WHERE compiler_status = 'Report Generation Completed'
              AND report_generation_transactions = 0
        ),

    'batches_report_generation_present_but_compiler_not_completed',
        COUNT(*) FILTER (
            WHERE report_generation_transactions > 0
              AND compiler_status IS DISTINCT FROM 'Report Generation Completed'
        ),

    'largest_mismatches',
        (
            SELECT COALESCE(jsonb_agg(to_jsonb(x)), '[]'::jsonb)
            FROM (
                SELECT
                    rpt_grp_id, rpt_grp_name, batch_id, seq_no,
                    actual_reportable_txn,
                    report_generation_transactions,
                    report_generation_minus_actual_reportable,
                    report_status, compiler_status, batch_status
                FROM joined
                ORDER BY ABS(report_generation_minus_actual_reportable) DESC
                LIMIT 25
            ) x
        )
) AS result
FROM joined;
```
