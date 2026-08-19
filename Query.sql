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
            ) AS rn

        FROM rule_hit_reconciliation r

        WHERE r.run_date >= TO_CHAR(:start_date, 'YYYYMMDD')::INTEGER
          AND r.run_date <= TO_CHAR(:end_date, 'YYYYMMDD')::INTEGER
    ) x

    WHERE rn = 1
)

SELECT
    SUM(COALESCE(distinct_rule_hits_count_iwra, 0))
        AS expected_rule_hits,

    SUM(COALESCE(distinct_rule_hits_count_pharos, 0))
        AS matched_rule_hits,

    SUM(COALESCE(missed_rule_hits_count_pharos, 0))
        AS missed_rule_hits,

    ROUND(
        100.0 *
        SUM(COALESCE(distinct_rule_hits_count_pharos, 0))
        /
        NULLIF(
            SUM(COALESCE(distinct_rule_hits_count_iwra, 0)),
            0
        ),
        2
    ) AS match_rate_pct

FROM latest_rule_recon;
