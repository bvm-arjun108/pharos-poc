# Operations / Reconciliation Dashboard — Consolidated Discovery

_Last consolidated: 2026-08-19._

This document combines the full discovery work completed for the Phase 1 operations/reconciliation dashboard: database structures, Scala/code findings, joins, validated equations, validation-query outcomes, dashboard implications, exclusions from scope, and the final implementation stance.

---

# 1. Goal and Scope

The dashboard must let operations users answer:

1. What ran in a selected period?
2. Which report groups and batches have issues?
3. What was expected versus actually processed/reported?
4. Which controls balanced or failed?
5. Which transactions were already reported, missing attempts, transformed, failed, duplicated, or excluded?
6. Can a user drill report group → batch → transaction/root cause?

The design should reflect the actual backend semantics rather than force every metric into a single linear funnel.

---

# 2. Phase 1 Core Tables

The final Phase 1 dependency set is:

- `pharos.report_transformation_reconciliation`
- `pharos.record_transformation_journey`
- `pharos.rule_hit`
- `pharos.rule_hit_exclusion_audit`
- `pharos.rule_hit_reconciliation`
- `pharos.report_batch_info`
- `pharos.report_group_config`

Three additional reconciliation-detail tables were discovered:

- `pharos.rule_hit_reconciliation_log`
- `pharos.rule_hit_reconciliation_analysis`
- `pharos.unprocessed_rule_hits`

Final decision: **these three are not required for Phase 1**. Missed Rule Hits remains aggregate-only unless a future requirement needs row-level missed-hit evidence.

---

# 3. Confirmed Table Structures

## 3.1 `pharos.rule_hit`

Confirmed columns:

| Column | Type |
|---|---|
| rpt_grp_id | integer |
| bucket_id | integer |
| rule_id | text/varchar |
| attempt_id | bigint |
| activity_type | text |
| batch_id | integer |
| created_timestamp | timestamptz |
| efile_batch_id | text/varchar |
| exclusion_reason_id | text |
| external_txn_key | bigint |
| galactic_id | text |
| is_reported | boolean |
| modified_timestamp | timestamptz |
| mtcn | text |
| objective_aggregation_key | text |
| reporting_timestamp | timestamp without time zone |
| rpt_grp_name | text |
| rule_currency_amount | numeric |
| rule_iso_currency_code | text |
| send_date | date |
| source | text |
| transaction_date | timestamp without time zone |
| transaction_side | text |
| reported_batch_id | text |

Important behavior from `RuleHitWriter`:

- `efile_batch_id` is set to the current transformation batch.
- `modified_timestamp` is updated.
- `is_reported` is explicitly set to `false`.
- No code was found in the reviewed transformer repository that sets `is_reported = true`.

Therefore `efile_batch_id` means the rule hit was associated with transformer/e-file output; it does **not** mean final downstream submission/reporting is complete.

Primary key confirmed from constants/code:

```text
(rpt_grp_id, bucket_id, rule_id, attempt_id)
```

## 3.2 `pharos.rule_hit_reconciliation`

Confirmed columns:

| Column | Type |
|---|---|
| rpt_grp_id | integer |
| run_date | integer |
| seq_no | integer |
| created_timestamp | timestamptz |
| data_selection_end_date | timestamp without time zone |
| data_selection_start_date | timestamp without time zone |
| distinct_rule_hits_count_iwra | integer |
| distinct_rule_hits_count_pharos | integer |
| missed_rule_hits_count_pharos | integer |
| modified_timestamp | timestamptz |
| rpt_grp_name | text |
| rule_hit_publish_count_iwra | integer |

Validated KPI mapping:

```text
Expected Rule Hits = distinct_rule_hits_count_iwra
Matched Rule Hits  = distinct_rule_hits_count_pharos
Missed Rule Hits   = missed_rule_hits_count_pharos
```

Validated relationship:

```text
Expected Rule Hits = Matched Rule Hits + Missed Rule Hits
```

Do **not** use `rule_hit_publish_count_iwra` as Expected; it did not consistently balance.

## 3.3 `pharos.rule_hit_exclusion_audit`

Confirmed columns:

| Column | Type |
|---|---|
| attempt_id | bigint |
| rpt_grp_id | integer |
| rule_id | text |
| bucket_id | integer |
| rpt_grp_name | text |
| external_txn_key | bigint |
| processing_batch_id | text |
| exclusion_reason_id | text |
| exclusion_strategy | text |
| reported_batch_id | text |
| mtcn | text |
| created_timestamp | timestamp without time zone |
| modified_timestamp | timestamp without time zone |
| reporting_timestamp | timestamp without time zone |

Preferred transformation bridge:

```text
report_transformation_reconciliation.batch_id
=
rule_hit_exclusion_audit.processing_batch_id
```

always scoped by `rpt_grp_id`.

## 3.4 `pharos.record_transformation_journey`

Confirmed columns:

| Column | Type |
|---|---|
| rpt_grp_id | integer |
| batch_id | text |
| identifier | text |
| mtcn | text |
| stage | text |
| status | text |
| comments | text |
| created_timestamp | timestamptz |
| modified_timestamp | timestamptz |
| reporting_timestamp_latest | timestamp without time zone |
| processing_complete | boolean |
| txn_metadata | jsonb |
| skip_reason | text |

Primary key confirmed:

```text
(rpt_grp_id, batch_id, identifier)
```

This table is therefore latest-state evidence per identifier, **not append-only event history**.

## 3.5 `pharos.report_transformation_reconciliation`

Confirmed columns:

| Column | Type |
|---|---|
| batch_id | text |
| seq_no | integer |
| rpt_grp_id | integer |
| rpt_grp_name | text |
| rpt_look_back_date | text |
| rpt_from_date | text |
| rpt_to_date | text |
| txn_selected | integer |
| txn_simulated | integer |
| excluded_txn | integer |
| txn_missing_attempt_count | integer |
| already_reported_count | integer |
| expected_reportable_txn | integer |
| actual_reportable_txn | integer |
| lookback_txn | integer |
| lookback_future_reporting_txn | integer |
| lookback_actual_txn | integer |
| reporting_period_txn | integer |
| reporting_period_future_reporting_txn | integer |
| reporting_period_actual_txn | integer |
| activity_selected | integer |
| activity_missing | integer |
| activity_simulated | integer |
| expected_activity_eligible_for_transformation | integer |
| actual_activity_eligible_for_transformation | integer |
| activity_transformed | integer |
| activity_transformation_failed | integer |
| duplicate_transformation | integer |
| created_timestamp | timestamp without time zone |
| modified_timestamp | timestamp without time zone |
| soft_dedup_dropped_txn_count | integer |

Confirmed semantic: this is the **batch-level** transformation reconciliation table.

For a batch dashboard, take the latest row per `(rpt_grp_id, batch_id)` ordered by:

```text
seq_no DESC,
modified_timestamp DESC NULLS LAST
```

## 3.6 `pharos.report_batch_info`

Confirmed primary key:

```text
(rpt_grp_id, batch_id, seq_no)
```

Observed useful fields include:

- `rpt_grp_id`
- `batch_id`
- `seq_no`
- `process_timestamp`
- `created_timestamp`
- `batch_status`
- `compiler_status`
- `report_status`
- `txn_lookback_start_timestamp`
- `txn_start_timestamp`
- `txn_end_timestamp`

Creation/update path:

- `ReportBatchTransformerProcessor.process()`
- creates `ReportBatchInfo(...)`
- writes through `ReportBatchInfoWriter.writeBatchInfo(...)`
- later updates through `writeStatus(...)`
- later report header updates through `writeReportHeader(...)`

Validated join:

```sql
rtr.rpt_grp_id = rbi.rpt_grp_id
AND rtr.batch_id = rbi.batch_id
AND rtr.seq_no = rbi.seq_no
```

## 3.7 `pharos.report_group_config`

Confirmed `ReportGroupConfig` fields:

```text
rptSelection
rptGrpId
inboundRuleId
outboundRuleId
transformerConfig
rptConfigActiveFlag
mappingProjectKey
mappingServiceName
countryName
rptGrpName
transformerVersionId
regReportableActivityColumns
ruleHitColumns
rptSelectionVersionId
rptPeriod
isPartialReport
isNonTransactionalReport
isBlankReport
createdTimestamp
modifiedTimestamp
additionalData
reportCurrency
dbLookupEnabled
manipulationStrategyMetadata
threeLetterCountryCode
columnToCompare
reconciliationStrategyMetadata
```

Confirmed DB mappings include:

```text
rpt_grp_id
rpt_grp_name
country_name
rpt_config_active_flag
transformer_version_id
rpt_selection_version_id
manipulation_strategy_metadata
reconciliation_strategy_metadata
```

Use Phase 1 for report-group name, country, active flag, and strategy/config metadata.

Not found in this repo:

- business owner
- operational owner
- assignee
- SLA owner
- richer jurisdiction metadata beyond country

---

# 4. Additional Discovered Reconciliation Detail Tables

These were found through database metadata discovery, investigated, and then intentionally excluded from the Phase 1 dependency set.

## 4.1 `pharos.rule_hit_reconciliation_analysis`

Observed columns:

| Column | Type |
|---|---|
| run_date | integer |
| seq_no | integer |
| rpt_grp_id | integer |
| txn_sur_key | text |
| rule_id | text |
| attempt_id | bigint |
| created_timestamp | timestamptz |
| description | text |
| modified_timestamp | timestamptz |
| mtcn | text |
| rpt_grp_name | text |

## 4.2 `pharos.rule_hit_reconciliation_log`

Observed columns include:

| Column | Type |
|---|---|
| run_date | integer |
| seq_no | integer |
| rpt_grp_id | integer |
| external_txn_key | text |
| rule_id | text |
| attempt_id | bigint |
| activity_type | text |
| batch_id | integer |
| bucket_id | integer |
| created_timestamp | timestamptz |
| data_source | text |
| efile_batch_id | text |
| exclusion_reason_id | text |
| future_reporting_date | timestamp without time zone |
| galactic_id | text |
| is_processed | boolean |
| is_reported | boolean |
| modified_timestamp | timestamptz |
| mtcn | text |
| objective_aggregation_key | text |
| reporting_timestamp | timestamp without time zone |
| retry_count | integer |
| rpt_grp_name | text |
| rule_currency_amount | numeric |
| rule_iso_currency_code | text |
| send_date | date |
| source | text |
| status | text |
| transaction_date | timestamp without time zone |
| transaction_side | text |

## 4.3 `pharos.unprocessed_rule_hits`

Observed columns include:

| Column | Type |
|---|---|
| activity_type | text |
| attempt_id | bigint |
| batch_id | integer |
| bucket_id | integer |
| created_timestamp | timestamptz |
| modified_timestamp | timestamptz |
| reporting_timestamp | timestamp without time zone |
| efile_batch_id | text |
| exclusion_reason_id | text |
| external_txn_key | bigint |
| galactic_id | text |
| is_reported | boolean |
| mtcn | text |
| objective_aggregation_key | text |
| rpt_grp_id | integer |
| rpt_grp_name | text |
| rule_currency_amount | numeric |
| rule_id | text |
| rule_iso_currency_code | text |
| send_date | date |
| source | text |
| transaction_date | timestamp without time zone |
| transaction_side | text |
| retry_count | integer |
| future_reporting_date | timestamp without time zone |
| status | text |
| correlation_id | text |
| data_source | text |

Final decision:

> Keep these out of Phase 1. They may be revisited only if genuine row-level missed-hit investigation becomes a requirement.

---

# 5. Scala / Code Discoveries

## 5.1 `RecordTransformationJourneyWriter`

Observed logic:

```scala
object RecordTransformationJourneyWriter {
  def write(sparkSession: SparkSession, df: DataFrame): Unit = {
    if (!df.isEmpty) {
      DbOperation.upsert(
        df,
        AppConstant.RECORD_TRANSFORMATION_JOURNEY_TABLE,
        AppConstant.RECORD_TRANSFORMATION_JOURNEY_TABLE_PRIMARY_KEY
      )
    }
  }
}
```

Implications:

- journey rows are upserted
- the table is latest-state evidence
- it is not a complete event-history table

## 5.2 `RuleHitWriter`

Observed `writeBatchId(...)` behavior:

- selects RuleHit DB fields
- writes `efile_batch_id = batchId`
- updates `modified_timestamp`
- writes `is_reported = false`
- upserts into `pharos.rule_hit`

Observed exclusion-update behavior:

- updates fields such as exclusion reason and reported-batch linkage
- persists through the same RuleHit upsert path

Implications:

- `efile_batch_id` is the correct transformation-batch bridge
- `rule_hit.batch_id` is not the transformation-batch bridge
- final `is_reported = true` occurs outside the reviewed transformer repo

## 5.3 `RuleHitExclusionAuditWriter`

Observed logic:

```scala
DbOperation.upsert(
  df.select(RuleHitExclusionAudit.asDbFields: _*),
  AppConstant.RULE_HITS_EXCLUSION_AUDIT_TABLE,
  AppConstant.RULE_HITS_EXCLUSION_AUDIT_PRIMARY_KEYS
)
```

Implication:

- exclusion evidence is materialized in its own audit table
- use it for drill-down where processing-batch linkage exists

## 5.4 `ReportBatchInfoWriter`

Observed methods:

- `writeBatchInfo(...)`
- `writeStatus(...)`
- `writeReportHeader(...)`

All persist to:

```text
pharos.report_batch_info
```

using the report-batch primary key.

## 5.5 Relevant `AppConstant` Discoveries

Confirmed table constants:

```text
REPORT_GROUP_CONFIG_TABLE = pharos.report_group_config
RULE_HITS_TABLE = pharos.rule_hit
RULE_HITS_EXCLUSION_AUDIT_TABLE = pharos.rule_hit_exclusion_audit
REPORT_BATCH_INFO_TABLE = pharos.report_batch_info
DATA_TRANSFORMATION_RECONCILIATION_TABLE = pharos.report_transformation_reconciliation
RECORD_TRANSFORMATION_JOURNEY_TABLE = pharos.record_transformation_journey
ATTEMPTS_BY_SURROGATE_KEYS = pharos.attempts_by_surrogate_key
```

Confirmed primary keys:

```text
RULE_HITS_TABLE_PRIMARY_KEY
= (rpt_grp_id, bucket_id, rule_id, attempt_id)

REPORT_BATCH_INFO_PRIMARY_KEY
= (rpt_grp_id, batch_id, seq_no)

RECORD_TRANSFORMATION_JOURNEY_TABLE_PRIMARY_KEY
= (rpt_grp_id, batch_id, identifier)
```

Observed configured exclusion-reason examples:

- `Refunded transaction`
- `Txn is already reported`
- `Send Paid attempt is Available`
- `Exclude this attempt to include latest Attempt`
- `Transaction Cancelled`

---

# 6. Reconciliation Strategy Classes

## 6.1 `ReconciliationIdentifierResolverFactory`

Supported pre-transformation reconciliation types:

```text
TRANSACTION_ONCE
INTRA_COUNTRY
TRANSACTION_PER_RULE
```

Unknown/unsupported types fall back to:

```text
TRANSACTION_ONCE
```

## 6.2 `PreTransformationResolver`

Discovered responsibilities:

- defines rule-hit key columns
- defines activity key columns
- extracts distinct reconciliation keys
- defines exclusion grouping
- computes a per-key exclusion flag

Important exclusion rule:

> A reconciliation key is treated as excluded only when all rows for that key have an exclusion reason.

## 6.3 `TransactionOncePreResolver`

```text
ruleHitKeyColumns = [externalTxnKey]
activityKeyColumns = [txnSurKey]
```

Activity-side mapping:

```text
txnSurKey -> externalTxnKey
```

## 6.4 `TransactionPerRulePreResolver`

```text
ruleHitKeyColumns = [externalTxnKey, ruleId]
activityKeyColumns = [txnSurKey, ruleId]
```

## 6.5 `IntraCountryPreResolver`

```text
ruleHitKeyColumns = [externalTxnKey, sideFlag]
activityKeyColumns = [txnSurKey, sideFlag]
```

`sideFlag` is derived from inbound/outbound rule configuration.

---

# 7. Exact Journey Markers Discovered

## 7.1 Already Reported

The counted population is materialized in journey where that branch writes evidence:

```text
stage    = 'FILTRATION'
status   = 'EXCLUDED'
comments = 'EXCLUDED_BECAUSE_ALREADY_REPORTED(PHAROS)'
```

Phase 1 pattern:

- aggregate count from `report_transformation_reconciliation.already_reported_count`
- row-level click-through to journey only where evidence exists

## 7.2 Missing Attempt

Exact marker:

```text
stage    = 'TRANSACTION_JOIN'
status   = 'ERROR'
comments = 'ATTEMPT_NOT_RECEIVED'
```

The underlying code joins rule hits to `attempts_by_surrogate_key` on `attempt_id`.

A reconciliation key is counted as missing-attempt only when all rows for that key have no matching transaction surrogate key.

The grouping key varies by reconciliation strategy:

```text
TRANSACTION_ONCE     -> externalTxnKey
TRANSACTION_PER_RULE -> (externalTxnKey, ruleId)
INTRA_COUNTRY        -> (externalTxnKey, sideFlag)
```

Important config nuance:

1. missing-attempt exclusion disabled:
   - no exclusion
   - no counted missing-attempt evidence from this branch
2. enabled + CSV logging:
   - rows may be logged to CSV
   - journey evidence is not guaranteed
3. enabled + non-CSV branch:
   - complete-failure transaction keys are removed
   - they are counted
   - journey evidence is written with `ATTEMPT_NOT_RECEIVED`

## 7.3 Transformation Success

```text
stage  = 'TRANSFORMATION'
status = 'SUCCESS'
```

## 7.4 Transformation Failure

Queried / observed as:

```text
stage  = 'TRANSFORMATION'
status = 'FAILURE'
```

with failure-related comments depending on the code path.

---

# 8. Future-Reporting Semantics

The future-reporting buckets are real transformer metrics.

## Lookback Future Reporting

Final predicate:

```text
reporting_timestamp >= lookback_start_ts
reporting_timestamp < from_ts
DATE(created_timestamp) > DATE(reporting_timestamp)
```

## Reporting-Period Future Reporting

Final predicate:

```text
reporting_timestamp >= from_ts
reporting_timestamp <= to_ts
DATE(created_timestamp) > DATE(reporting_timestamp)
```

These are calculated after the reportable population is filtered.

Important preceding filters/steps include:

1. rule-hit selection by batch date/report group/rule list
2. `efile_batch_id IS NULL`
3. `exclusion_reason_id IS NULL`
4. SML removal:
   - `galactic_id NOT LIKE '%SML%'` or null
   - `mtcn NOT LIKE '%SML%'` or null
5. missing-attempt handling
6. already-reported exclusion
7. soft-dedup exclusion according to report-group strategy

Therefore:

- aggregate future-reporting metrics are safe to display
- exact clickable row-level future-reporting requires correct report-group-specific reconstruction of the included population

Phase 1 stance:

> Show future-reporting aggregates, but do not promise universal row-level drill-down until strategy/config-dependent inclusion logic is fully parameterized.

---

# 9. Validated Control Equations

A major discovery was that the dashboard must **not** use one fake linear transaction funnel.

## 9.1 Rejected Selection Equation

This equation was tested and found non-universal:

```text
txn_selected
=
excluded_txn
+ txn_missing_attempt_count
+ already_reported_count
+ expected_reportable_txn
```

Earlier August validation:

```text
total_batches = 312
selection_balanced_batches = 176
selection_unbalanced_batches = 136
max_selection_difference = 1002
```

Conclusion:

> Do not show this as a complete waterfall/funnel.

## 9.2 Lookback Control

Validated:

```text
lookback_txn
=
lookback_actual_txn
+
lookback_future_reporting_txn
```

Earlier August:

```text
312 / 312 balanced
```

June revalidation also showed full balance over the tested latest-batch population.

## 9.3 Reporting-Period Control

Validated:

```text
reporting_period_txn
=
reporting_period_actual_txn
+
reporting_period_future_reporting_txn
```

Earlier August:

```text
312 / 312 balanced
```

June revalidation also showed full balance.

## 9.4 Activity Composition

Strongly validated:

```text
activity_selected
=
lookback_txn
+
reporting_period_txn
+
activity_simulated
```

Earlier August:

```text
311 / 312 balanced
```

June Query 02:

```text
activity_selected_balanced = 564
activity_selected_unbalanced = 2
```

## 9.5 Reportable Control

Useful independent control:

```text
expected_reportable_txn
vs
actual_reportable_txn
```

June Query 02:

```text
reportable_balanced = 534
reportable_unbalanced = 32
```

Do not assume `expected_reportable_txn = activity_selected` universally.

Earlier August validation:

```text
expected_equals_activity_selected = 298
expected_not_equal_activity_selected = 14
```

Large mismatches were observed for report groups including:

- Australia IFTI
- Philippines CTR
- Indonesia SIPESAT

## 9.6 Transformation Control

Code review changed the interpretation here.

Primary control:

```text
actual_activity_eligible_for_transformation
=
activity_transformed
+
activity_transformation_failed
```

`duplicate_transformation` is **not** part of the primary balance equation. It is a separate quality metric.

June Query 02:

```text
Primary transformation formula:
balanced   = 512
unbalanced = 54

Formula including duplicate_transformation:
balanced   = 493
unbalanced = 73
```

Therefore the formula including duplicates is weaker and should not be used as the primary control.

## 9.7 Duplicate Transformation

Treat separately as a quality signal, not as an accounting leg of the primary transformation control.

---

# 10. Validated Batch Bridges

The batch linkage tests established the following.

## 10.1 Rule Hit Bridge

Strongest bridge:

```sql
rtr.rpt_grp_id = rh.rpt_grp_id
AND rtr.batch_id = rh.efile_batch_id
```

Earlier batch-bridge validation across 312 transformation batches:

```text
rule_hit.efile_batch_id
-> 26,166 matched rows
-> 59 matched batch keys
```

By contrast:

```text
rule_hit.batch_id
-> 0 matched transformation batch keys
```

Therefore:

> `rule_hit.batch_id` is definitively not the transformation-batch bridge.

## 10.2 Exclusion Audit Bridge

Preferred bridge:

```sql
rtr.rpt_grp_id = ea.rpt_grp_id
AND rtr.batch_id = ea.processing_batch_id
```

Earlier validation:

```text
rule_hit_exclusion_audit.processing_batch_id
-> 3,649 matched rows
-> 33 matched batch keys
```

Secondary/later reporting linkages:

```text
rule_hit_exclusion_audit.reported_batch_id
-> 2,046 rows
-> 8 batch keys

rule_hit.reported_batch_id
-> 2,031 rows
-> 6 batch keys
```

These are later output/reporting linkages rather than the preferred transformation-processing bridge.

---

# 11. Validated Transaction Bridges

Transaction-level matching was explicitly tested.

## 11.1 Primary Transaction Bridge

Preferred:

```sql
rh.rpt_grp_id = rtj.rpt_grp_id
AND rh.efile_batch_id = rtj.batch_id
AND rh.mtcn = rtj.mtcn
```

Earlier validation:

```text
matched journey transactions: 26,185
uniquely matched:             26,185
ambiguous:                    0
```

## 11.2 Fallback Transaction Bridge

Fallback:

```sql
rh.rpt_grp_id = rtj.rpt_grp_id
AND rh.efile_batch_id = rtj.batch_id
AND rh.external_txn_key::text = rtj.identifier
```

Earlier validation:

```text
matched:         21,862
uniquely matched 21,862
ambiguous:       0
```

## 11.3 Sparse Candidate — Do Not Rely On

Candidate:

```text
txn_metadata.txn_sur_key -> rule_hit.external_txn_key
```

Earlier validation found only ~40 matches.

Conclusion:

- MTCN is the primary validated transaction bridge when available.
- `identifier` → `external_txn_key` is a good fallback.
- Never join globally by MTCN alone; always include report-group and batch context.

---

# 12. Report-Group / Batch Coverage Observations

Rule-hit and exclusion evidence is not universal.

Earlier bridge-by-report-group examples:

## Australia IFTI (`rpt_grp_id = 2217`)

```text
transformation_batches       = 25
batches_with_rule_hits       = 9
batches_with_exclusions      = 4
total_rule_hit_rows          = 1,828
total_distinct_mtcns         = 1,828
total_distinct_rules         = 15
total_exclusion_rows         = 510
```

## Philippines CTR (`rpt_grp_id = 230000004`)

```text
transformation_batches       = 43
batches_with_rule_hits       = 8
batches_with_exclusions      = 0
total_rule_hit_rows          = 6,025
total_distinct_mtcns         = 6,025
total_distinct_rules         = 8
```

## Turkey Outbound Objective

```text
transformation_batches       = 27
batches_with_rule_hits       = 4
batches_with_exclusions      = 2
```

## Norway Objective

```text
transformation_batches       = 19
batches_with_rule_hits       = 4
batches_with_exclusions      = 2
```

## Panama Objective

```text
transformation_batches       = 3
batches_with_rule_hits       = 3
batches_with_exclusions      = 2
```

Conclusion:

> Rule Hits and Exclusions must be conditional tabs, not assumed universal batch features.

---

# 13. Rule-Hit Reconciliation Discoveries

## 13.1 Validated Aggregate Equation

Earlier validation showed:

```text
total reconciliation rows = 3
distinct equation balances = 3
distinct equation failures = 0

publish equation balances = 1
publish equation failures = 2
```

Therefore:

```text
distinct_rule_hits_count_iwra
=
distinct_rule_hits_count_pharos
+
missed_rule_hits_count_pharos
```

is validated.

`rule_hit_publish_count_iwra` is not a reliable Expected value.

## 13.2 June Revalidation Example

One tested period returned:

```json
{
  "query_id": "VAL_10_RECONCILIATION_GRAINS",
  "total_rows": 6,
  "balanced_rows": 6,
  "distinct_runs": 6,
  "unbalanced_rows": 0,
  "missed_rule_hits": 78,
  "matched_rule_hits": 0,
  "expected_rule_hits": 78,
  "distinct_report_groups": 3
}
```

The tested report groups included examples such as:

- Norway Objective
- Turkey Monthly Objective
- Turkey Outbound Objective

## 13.3 Missed-Hit Row-Level Problem

The aggregate missed count is validated. Row-level missed-hit reconstruction from `rule_hit` is **not**.

Tests using predicates such as:

- `exclusion_reason_id IS NULL AND is_reported = false`
- `exclusion_reason_id IS NULL AND is_reported IS NOT TRUE`
- `reporting_timestamp IS NULL`
- `reported_batch_id IS NULL`

did not reconcile to aggregate missed counts.

A key diagnostic example:

```text
Norway Objective
expected = 12
matched  = 0
missed   = 12
```

yet the corresponding business-window search in `rule_hit` produced no source rows.

Working conclusion:

> The expected/source reconciliation population can include records for which no `rule_hit` row exists. Therefore missed rows cannot reliably be reconstructed by filtering `rule_hit` alone.

Final Phase 1 decision:

> Missed Rule Hits is aggregate-only.

---

# 14. Date Semantics

Multiple date concepts exist and must not be conflated.

## Transformation Dashboard Execution Period

Previously validated monthly queries used:

```text
report_transformation_reconciliation.created_timestamp
```

For operational batch timing, `report_batch_info.process_timestamp` is also useful.

## Rule-Hit Reconciliation

Contains:

- `run_date`
- `created_timestamp`
- `data_selection_start_date`
- `data_selection_end_date`

Observed behavior proved the reconciliation execution date can be in 2026 while the business data-selection window references earlier dates.

Example discovered:

```text
created_timestamp: 2026-07-15...
data_selection_start_date: 2025-12-15
data_selection_end_date:   2025-12-17
```

Therefore:

- use execution timestamps for "what ran in this period"
- show business selection windows separately
- do not assume `run_date` is necessarily the same semantic as business transaction date

Exact `run_date` business meaning remains an external/unknown detail.

---

# 15. Query Catalog and Outcomes

The final validation/discovery sequence included:

```text
Q01  Confirm report_batch_info join and dashboard timestamp
Q02  Revalidate all batch control equations
Q03  Validate future-reporting aggregate metrics
Q04  Prove already_reported_count against journey evidence
Q05  Prove txn_missing_attempt_count against journey evidence
Q06  Validate transformed/failed counts against journey evidence
Q07  Validate duplicate transformation as a separate quality signal
Q08  Validate rule-hit batch linkage and unreported population
Q09  Validate exclusion-audit coverage
Q10  Validate reconciliation aggregate equations
Q11  Discover production batch-status values
Q12  Discover reconciliation-detail candidate tables
Q13  Validate reconciliation-detail populations
Q14  Validate reconciliation-detail linkage
Q15  Validate missed-hit evidence
```

## Q01 — Batch Join and Time

Confirmed:

```text
report_transformation_reconciliation
<-> report_batch_info
```

joins correctly on:

```text
(rpt_grp_id, batch_id, seq_no)
```

Useful operational fields observed:

- `process_timestamp`
- `batch_status`
- `compiler_status`
- `report_status`
- batch-info created timestamp
- reconciliation created timestamp

## Q02 — Batch Control Equations

June result:

```json
{
  "query_id": "VAL_02_BATCH_CONTROL_EQUATIONS",
  "total_batches": 566,
  "lookback_balanced": 566,
  "lookback_unbalanced": 0,
  "reportable_balanced": 534,
  "reportable_unbalanced": 32,
  "reporting_period_balanced": 566,
  "reporting_period_unbalanced": 0,
  "activity_selected_balanced": 564,
  "activity_selected_unbalanced": 2,
  "transformation_balance_formula": {
    "balanced": 512,
    "unbalanced": 54
  },
  "transformation_balance_with_duplicate": {
    "balanced": 493,
    "unbalanced": 73
  }
}
```

## Q03 — Future Reporting

June result:

```text
total_batches = 566
batches_with_any_future_reporting = 20
batches_with_lookback_future_reporting = 0
batches_with_reporting_period_future_reporting = 20
```

Observed total shape:

```text
sum_lookback_txn                  ≈ 11,900
sum_lookback_actual_txn           ≈ 11,900
sum_lookback_future_reporting_txn = 0

sum_reporting_period_txn                  ≈ 99,553
sum_reporting_period_actual_txn           ≈ 92,200
sum_reporting_period_future_reporting_txn ≈ 7,355
```

## Q04 — Already Reported vs Journey

Observed:

```text
total_batches = 566
batches_with_any_journey = 491
metric_nonzero_marker_zero = 2
batches_with_metric_nonzero = 113
balanced_when_journey_exists = 484
exactly_balanced_all_batches = 558
```

Conclusion:

- reconciliation metric is authoritative for aggregate count
- journey gives strong but not universal row-level evidence

## Q05 — Missing Attempt vs Journey

Observed batches with nonzero:

```text
txn_missing_attempt_count
```

and zero:

```text
missing_attempt_journey_rows
```

Conclusion:

- aggregate metric is safe
- journey drill-down must be conditional/config-aware

## Q06 — Transformation vs Journey

Observed:

```text
total_batches = 566
batches_with_any_journey = 491
transformed_exactly_balanced = 540
failed_exactly_balanced = 489
```

Conclusion:

- transformation journey drill-down is useful
- aggregate metrics remain authoritative

## Q07 — Duplicate Transformation

Observed:

```json
{
  "query_id": "VAL_07_DUPLICATE_TRANSFORMATION",
  "total_batches": 566,
  "total_duplicates": 2151,
  "batches_with_duplicates": 34
}
```

Conclusion:

- duplicates are operationally meaningful
- show them as a separate quality signal

## Q08 — Rule Hit Batch Linkage

Observed:

```json
{
  "query_id": "VAL_08_RULE_HIT_BATCH_LINKAGE",
  "rule_hit_rows": 8413,
  "distinct_batches": 36,
  "is_reported_null": 0,
  "is_reported_true": 8385,
  "is_reported_false": 28
}
```

Conclusion:

- `efile_batch_id` bridge is valid
- final `is_reported=true` updates occur outside reviewed transformer code

## Q09 — Exclusion Audit

Observed:

```text
audit_rows = 5,185
distinct_batches = 27
```

Observed exclusion reasons included:

- Transaction already reported
- Transaction already reported on this side
- Exclude this attempt to include latest Attempt - GID ReResolve
- `<NULL>`

Conclusion:

- exclusion audit supports drill-down where coverage exists

## Q10 — Rule-Hit Reconciliation

Validated aggregate equation as described above.

## Q11 — Batch Status Discovery

Observed:

```json
{
  "query_id": "DISC_11_BATCH_STATUS_VALUES",
  "total_rows": 535,
  "batch_status_counts": {
    "Failed": 256,
    "Generated": 236,
    "In Progress": 41,
    "Acknowledgement": 2
  },
  "report_status_counts": {
    "ALL": 40,
    "BLANK": 1,
    "<NULL>": 22,
    "FAILED": 243,
    "PARTIAL": 182,
    "NO_QUALIFIED_TRANSACTIONS": 47
  }
}
```

Observed compiler statuses included:

- Partial
- Success
- Blank Report
- Data Selection Failed
- Data Selection Completed
- No Qualified Transaction
- Report Generation Failed
- Report Generation Started
- Data Transformation Failed
- Data Transformation Started
- Report Generation Completed
- Data Transformation Completed

Conclusion:

> Health must be based on an explicit status/control mapping, not a single raw field.

## Q12 — Candidate Reconciliation Detail Tables

Discovered:

```text
rule_hit_reconciliation_analysis
rule_hit_reconciliation_log
unprocessed_rule_hits
```

## Q13–Q15 — Detail Population / Linkage / Missed-Hit Evidence

The tested execution window returned no useful rows/evidence.

Final design decision:

> Do not depend on these tables for Phase 1.

---

# 16. Dashboard UX Implications

## 16.1 Main Dashboard

Recommended filters:

- Date Range
- Report Group
- Batch ID
- optional Rule / Source where relevant

Recommended KPI groups:

### Operational Coverage

- Batches Run
- Report Groups Run
- Batches With Issues
- Critical / Failed Batches

### Rule-Hit Coverage

- Expected Rule Hits
- Matched Rule Hits
- Missed Rule Hits
- Match Rate

### Processing Exceptions

- Missing Attempts
- Transformation Failures
- Duplicate Transformations
- Reconciliation Issue Batches
- optionally Control-Imbalance Batches

## 16.2 Report Group Health Table

Recommended columns:

- Report Group
- Country
- Batches Run
- Batches With Issues
- Expected Rule Hits
- Matched Rule Hits
- Missed Rule Hits
- Match %
- Missing Attempts
- Transformation Failures
- Duplicate Transformations
- Reconciliation Issues
- Health

Clicking a report group must scope subsequent drill-downs to that report group.

## 16.3 Batch Control Room

Recommended sections:

### Header

- report group
- country
- batch ID
- process time
- batch status
- compiler status
- report status
- health

### Reporting Control

```text
Expected Reportable
Actual Reportable
Difference
```

### Lookback Control

```text
Lookback Total
Lookback Actual
Lookback Future Reporting
Balance
```

### Reporting Period Control

```text
Reporting Period Total
Reporting Period Actual
Reporting Period Future Reporting
Balance
```

### Activity Composition

```text
Activity Selected
Lookback
Reporting Period
Simulated
Balance
```

### Transformation Control

```text
Eligible
Transformed
Failed
Difference
```

### Separate Quality Signal

```text
Duplicate Transformations
```

### Other Operational Counters

- Missing Attempts
- Excluded Transactions
- Already Reported
- Activity Missing
- Soft Dedup Dropped

## 16.4 Conditional Tabs

Recommended tabs:

```text
Overview
Controls
Journey
Rule Hits
Exclusions
```

But:

- show Journey only when evidence exists
- show Rule Hits only when linked `rule_hit` rows exist
- show Exclusions only when linked exclusion rows exist

No empty tabs.

## 16.5 Transaction Root-Cause View

Potential evidence:

- journey stage/status/comments
- skip reason
- rule-hit evidence
- rule ID
- MTCN
- external transaction key
- exclusion reason/strategy
- processing batch
- reported batch where available

---

# 17. Status Ownership and Reporting Semantics

The reviewed transformer code sets:

```text
rule_hit.efile_batch_id = current batch
rule_hit.is_reported = false
```

No setter for `is_reported = true` was found in this repository.

Therefore Phase 1 must distinguish:

1. Included in transformer/e-file output
2. Finally reported/submitted downstream

Do not let the UI imply that the transformer owns final reporting completion.

---

# 18. Journey Coverage Caveats

Journey is not guaranteed for every transaction or every report group.

Reasons discovered:

1. journey writing is gated by report-group config
2. some missing-attempt branches can log to CSV instead
3. journey is an upserted latest-state table
4. some aggregate metrics exist even when corresponding journey markers are absent

Recommended fallback message:

```text
No journey evidence available for this transaction/batch.
```

---

# 19. Health Semantics

Do not infer health from one raw status alone.

Health should consider:

- `batch_status`
- `compiler_status`
- `report_status`
- reportable reconciliation difference
- transformation failures
- duplicate transformations
- missing attempts
- validated control imbalance
- missed rule-hit coverage where applicable

Potential UI categories:

```text
Healthy
Warning
Critical
Failed
In Progress
```

but the mapping should be explicit and conservative.

---

# 20. Final Join Reference

## Reconciliation → Batch Info

```sql
rtr.rpt_grp_id = rbi.rpt_grp_id
AND rtr.batch_id = rbi.batch_id
AND rtr.seq_no = rbi.seq_no
```

## Reconciliation → Journey

```sql
rtr.rpt_grp_id = rtj.rpt_grp_id
AND rtr.batch_id = rtj.batch_id
```

## Reconciliation → Rule Hit

```sql
rtr.rpt_grp_id = rh.rpt_grp_id
AND rtr.batch_id = rh.efile_batch_id
```

## Reconciliation → Exclusion Audit

```sql
rtr.rpt_grp_id = ea.rpt_grp_id
AND rtr.batch_id = ea.processing_batch_id
```

## Journey → Rule Hit — Primary

```sql
rtj.rpt_grp_id = rh.rpt_grp_id
AND rtj.batch_id = rh.efile_batch_id
AND rtj.mtcn = rh.mtcn
```

## Journey → Rule Hit — Fallback

```sql
rtj.rpt_grp_id = rh.rpt_grp_id
AND rtj.batch_id = rh.efile_batch_id
AND rtj.identifier = rh.external_txn_key::text
```

---

# 21. What Is Safe to Implement Now

1. batch/report-group processing controls from `report_transformation_reconciliation`
2. operational batch status/time from `report_batch_info`
3. report-group metadata from `report_group_config`
4. aggregate already-reported count
5. already-reported journey drill-down where evidence exists
6. aggregate missing-attempt count
7. missing-attempt journey drill-down where evidence exists
8. transformation success/failure controls
9. transformation journey evidence where present
10. duplicate transformation as a separate quality signal
11. rule-hit drill-down using `efile_batch_id`
12. exclusion drill-down using `processing_batch_id`
13. Expected / Matched / Missed aggregate rule-hit KPIs
14. future-reporting aggregate metrics
15. conditional evidence tabs

---

# 22. What Still Requires Caution

1. future-reporting row-level click-through
2. strategy-dependent raw-rule-hit reconstruction
3. journey-dependent explanations where journey writing was disabled
4. precise external owner of `is_reported=true`
5. authoritative semantics of `rule_hit_reconciliation.run_date`
6. true row-level missed-hit population

---

# 23. What Must Not Be Implemented as if Validated

1. a single linear transaction funnel from selected to expected reportable
2. universal `expected_reportable_txn = activity_selected`
3. duplicate transformation inside the primary transformation balance equation
4. `rule_hit.batch_id` as the transformation batch key
5. MTCN-only global joins without report-group + batch context
6. fake row-level Missed Rule Hit drill-down from `rule_hit`
7. an assumption that journey exists for every transaction
8. an assumption that transformer output means final submission complete

---

# 24. Final Phase 1 Page Map

```text
Main Operations Dashboard
    |
    +-- Report Group Drill-Down
    |      |
    |      +-- Batch Control Room
    |
    +-- Batch Investigation Queue
           |
           +-- Batch Control Room
                  |
                  +-- Overview
                  +-- Controls
                  +-- Journey       [conditional]
                  +-- Rule Hits     [conditional]
                  +-- Exclusions    [conditional]
                         |
                         +-- Transaction Root Cause
```

---

# 25. Final Architectural Conclusions

1. `report_transformation_reconciliation` is the batch-level control source.
2. `record_transformation_journey` is latest-state record-level evidence, not universal event history.
3. `report_batch_info` is the best batch operational status/time source.
4. `report_group_config` is the reference source for report-group metadata/config.
5. `rule_hit.efile_batch_id` is the validated transformation batch bridge.
6. `rule_hit_exclusion_audit.processing_batch_id` is the validated exclusion-processing bridge.
7. `rule_hit_reconciliation` safely supports aggregate Expected / Matched / Missed Rule Hit KPIs.
8. Missed Rule Hits should remain aggregate-only in Phase 1.
9. `duplicate_transformation` is a separate quality metric.
10. The transaction-selection metrics do not form one universal linear funnel.
11. Transformer output must be distinguished from final downstream reporting.
12. Evidence tabs and drill-downs must be conditional.
13. The dashboard can be implemented without `rule_hit_reconciliation_log`, `rule_hit_reconciliation_analysis`, or `unprocessed_rule_hits`.

---

# 26. Final Implementation Principle

The dashboard should prioritize:

```text
operational truth
over
visual symmetry
```

Only show a control as an equation when that relationship has been validated.

Only show a drill-down when supporting row-level evidence exists.

Do not force aggregate metrics into transaction-level explainability where the backend does not support it reliably.

That keeps Phase 1 defensible, operationally useful, and aligned with the real transformer/reconciliation architecture.
