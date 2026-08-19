1. 1. Find every table/view containing IWRA-related columns
  
WITH matches AS (
    SELECT
        table_schema,
        table_name,
        table_type,
        column_name,
        data_type
    FROM information_schema.columns c
    JOIN information_schema.tables t
      USING (table_schema, table_name)
    WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
      AND (
           LOWER(column_name) LIKE '%iwra%'
        OR LOWER(column_name) LIKE '%rule_hit%'
        OR LOWER(column_name) LIKE '%publish_count%'
        OR LOWER(column_name) LIKE '%missed%'
      )
)

SELECT jsonb_build_object(
    'query_id', 'DISCOVERY_01_IWRA_COLUMNS',
    'objects',
    COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'schema', table_schema,
                'object_name', table_name,
                'object_type', table_type,
                'column_name', column_name,
                'data_type', data_type
            )
            ORDER BY table_schema, table_name, column_name
        ),
        '[]'::jsonb
    )
) AS result
FROM matches;


===========================================================================
2. Search all views for where distinct_rule_hits_count_iwra is calculated

  WITH matches AS (
    SELECT
        schemaname,
        viewname,
        definition
    FROM pg_views
    WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
      AND (
           LOWER(definition) LIKE '%distinct_rule_hits_count_iwra%'
        OR LOWER(definition) LIKE '%rule_hit_publish_count_iwra%'
        OR LOWER(definition) LIKE '%missed_rule_hits_count_pharos%'
        OR LOWER(definition) LIKE '%iwra%'
      )
)

SELECT jsonb_build_object(
    'query_id', 'DISCOVERY_02_IWRA_VIEWS',
    'matching_views',
    COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'schema', schemaname,
                'view_name', viewname,
                'definition', definition
            )
            ORDER BY schemaname, viewname
        ),
        '[]'::jsonb
    )
) AS result
FROM matches;

  




===========================================================================
3. Search stored functions/procedures for the reconciliation logic

  
WITH function_defs AS MATERIALIZED (
    SELECT
        n.nspname AS schema_name,
        p.proname AS function_name,
        p.prokind,

        CASE
            WHEN p.prokind IN ('f', 'p')
            THEN pg_get_functiondef(p.oid)
            ELSE NULL
        END AS definition

    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace

    WHERE n.nspname NOT IN (
        'pg_catalog',
        'information_schema'
    )
),

matches AS (
    SELECT
        schema_name,
        function_name,
        CASE
            WHEN prokind = 'p' THEN 'PROCEDURE'
            ELSE 'FUNCTION'
        END AS object_type,
        definition

    FROM function_defs

    WHERE definition IS NOT NULL
      AND (
           LOWER(definition) LIKE '%distinct_rule_hits_count_iwra%'
        OR LOWER(definition) LIKE '%rule_hit_publish_count_iwra%'
        OR LOWER(definition) LIKE '%missed_rule_hits_count_pharos%'
        OR LOWER(definition) LIKE '%rule_hit_reconciliation%'
        OR LOWER(definition) LIKE '%iwra%'
      )
)

SELECT jsonb_build_object(
    'query_id',
        'DISCOVERY_03_IWRA_FUNCTIONS',

    'matching_functions',
        COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'schema', schema_name,
                    'object_name', function_name,
                    'object_type', object_type,
                    'definition', definition
                )
                ORDER BY schema_name, function_name
            ),
            '[]'::jsonb
        )
) AS result

FROM matches;







===========================================================================

4. Find candidate transaction-level tables

  WITH candidate_columns AS (
    SELECT
        table_schema,
        table_name,

        COUNT(*) FILTER (
            WHERE LOWER(column_name) IN (
                'rpt_grp_id',
                'report_group_id'
            )
        ) AS has_report_group,

        COUNT(*) FILTER (
            WHERE LOWER(column_name) IN (
                'rule_id',
                'rule'
            )
        ) AS has_rule,

        COUNT(*) FILTER (
            WHERE LOWER(column_name) IN (
                'mtcn',
                'external_txn_key',
                'transaction_id',
                'txn_id',
                'identifier'
            )
        ) AS has_transaction,

        COUNT(*) FILTER (
            WHERE LOWER(column_name) LIKE '%batch%'
        ) AS has_batch,

        COUNT(*) FILTER (
            WHERE LOWER(column_name) LIKE '%date%'
               OR LOWER(column_name) LIKE '%timestamp%'
        ) AS has_date

    FROM information_schema.columns

    WHERE table_schema NOT IN (
        'pg_catalog',
        'information_schema'
    )

    GROUP BY
        table_schema,
        table_name
),

candidates AS (
    SELECT *
    FROM candidate_columns
    WHERE has_report_group > 0
      AND has_transaction > 0
)

SELECT jsonb_build_object(
    'query_id', 'DISCOVERY_04_TRANSACTION_SOURCE_CANDIDATES',

    'candidate_tables',
    COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'schema', table_schema,
                'table_name', table_name,
                'has_report_group', has_report_group,
                'has_rule', has_rule,
                'has_transaction', has_transaction,
                'has_batch', has_batch,
                'has_date', has_date
            )
            ORDER BY
                has_rule DESC,
                has_batch DESC,
                has_date DESC,
                table_name
        ),
        '[]'::jsonb
    )
) AS result

FROM candidates;







===========================================================================

5. Search object names themselves

  SELECT jsonb_build_object(
    'query_id', 'DISCOVERY_05_OBJECT_NAMES',

    'objects',
    COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'schema', table_schema,
                'object_name', table_name,
                'object_type', table_type
            )
            ORDER BY table_schema, table_name
        ),
        '[]'::jsonb
    )
) AS result

FROM information_schema.tables

WHERE table_schema NOT IN ('pg_catalog', 'information_schema')

AND (
       LOWER(table_name) LIKE '%iwra%'
    OR LOWER(table_name) LIKE '%rule%hit%'
    OR LOWER(table_name) LIKE '%recon%'
    OR LOWER(table_name) LIKE '%report%'
    OR LOWER(table_name) LIKE '%objective%'
    OR LOWER(table_name) LIKE '%publish%'
);






===========================================================================








===========================================================================








===========================================================================







===========================================================================








===========================================================================
