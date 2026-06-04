"""Case data access. Swap between mock sample data and real Snowflake via env."""
from typing import Protocol

from .config import settings
from .models import CaseRecord, GsiHit, History, Party

# --------------------------------------------------------------------------- #
# Sample cases — stand in for the Snowflake fetch so you can run with no data
# dependency. 8042196375 is a high-risk structuring/OFAC pattern;
# 5113380027 is a clean low-risk remittance.
# --------------------------------------------------------------------------- #
SAMPLE_CASES = {
    "8042196375": CaseRecord(
        mtcn="8042196375",
        sender=Party(name="Ahmed K.", country="United Arab Emirates", id_type="Passport"),
        receiver=Party(name="Viktor S.", country="Cyprus", id_type="National ID"),
        amount=9450, currency="USD", corridor="UAE → Cyprus", channel="Agent location",
        gsi_hit=GsiHit(
            list="OFAC SDN — potential match", matched_name="Viktor S.",
            match_score=0.83, matched_fields=["name", "partial DOB"],
        ),
        history=History(transfers_30d=7, total_30d_usd=61200, avg_amount_usd=8740),
        flags=[
            "Amounts consistently just under the $10,000 reporting threshold",
            "Receiver added to sender's profile 9 days ago",
        ],
    ),
    "5113380027": CaseRecord(
        mtcn="5113380027",
        sender=Party(name="María L.", country="United States", id_type="Driver License"),
        receiver=Party(name="José L.", country="Mexico", id_type="INE"),
        amount=280, currency="USD", corridor="USA → Mexico", channel="Mobile app",
        gsi_hit=GsiHit(
            list="Internal watchlist — weak name match", matched_name="Jose Lopez",
            match_score=0.51, matched_fields=["name"],
        ),
        history=History(transfers_30d=2, total_30d_usd=540, avg_amount_usd=270),
        flags=["Consistent monthly remittance pattern", "Long-standing sender/receiver relationship"],
    ),
}


class CaseRepository(Protocol):
    def get_case(self, mtcn: str) -> CaseRecord: ...


class MockCaseRepository:
    def get_case(self, mtcn: str) -> CaseRecord:
        if mtcn in SAMPLE_CASES:
            return SAMPLE_CASES[mtcn]
        # Generic sample for any other MTCN so the demo never dead-ends.
        return CaseRecord(
            mtcn=mtcn,
            sender=Party(name="Unknown sender", country="—", id_type="—"),
            receiver=Party(name="Flagged receiver", country="—", id_type="—"),
            amount=4200, currency="USD", corridor="—", channel="Agent location",
            gsi_hit=GsiHit(list="Screening hit — sample", matched_name="—",
                           match_score=0.62, matched_fields=["name"]),
            history=History(transfers_30d=3, total_30d_usd=11800, avg_amount_usd=3930),
            flags=["Sample case generated for this MTCN"],
        )


class SnowflakeCaseRepository:
    """Real Snowflake adapter. ADAPT the SQL + column mapping to your Pharos schema."""

    def __init__(self):
        import snowflake.connector  # imported lazily so mock mode needs no driver

        self._sf = snowflake.connector

    def _connect(self):
        return self._sf.connect(
            account=settings.SNOWFLAKE_ACCOUNT,
            user=settings.SNOWFLAKE_USER,
            password=settings.SNOWFLAKE_PASSWORD,
            warehouse=settings.SNOWFLAKE_WAREHOUSE,
            database=settings.SNOWFLAKE_DATABASE,
            schema=settings.SNOWFLAKE_SCHEMA,
            role=settings.SNOWFLAKE_ROLE,
        )

    def get_case(self, mtcn: str) -> CaseRecord:
        # NOTE: this query and the row->CaseRecord mapping below are a template.
        # Replace table/column names with your actual Pharos schema. Always use
        # a parameterized query (never string-format the MTCN into the SQL).
        sql = """
            SELECT mtcn, sender_name, sender_country, sender_id_type,
                   receiver_name, receiver_country, receiver_id_type,
                   amount, currency, corridor, channel,
                   gsi_list, gsi_matched_name, gsi_match_score, gsi_matched_fields,
                   transfers_30d, total_30d_usd, avg_amount_usd, flags
            FROM cases
            WHERE mtcn = %(mtcn)s
        """
        conn = self._connect()
        try:
            cur = conn.cursor(self._sf.DictCursor)
            cur.execute(sql, {"mtcn": mtcn})
            row = cur.fetchone()
        finally:
            conn.close()

        if not row:
            raise ValueError(f"No case found for MTCN {mtcn}")

        def split(v):
            if isinstance(v, (list, tuple)):
                return list(v)
            return [s.strip() for s in str(v).split(",") if s.strip()] if v else []

        return CaseRecord(
            mtcn=str(row["MTCN"]),
            sender=Party(name=row["SENDER_NAME"], country=row["SENDER_COUNTRY"], id_type=row["SENDER_ID_TYPE"]),
            receiver=Party(name=row["RECEIVER_NAME"], country=row["RECEIVER_COUNTRY"], id_type=row["RECEIVER_ID_TYPE"]),
            amount=float(row["AMOUNT"]), currency=row["CURRENCY"],
            corridor=row["CORRIDOR"], channel=row["CHANNEL"],
            gsi_hit=GsiHit(
                list=row["GSI_LIST"], matched_name=row["GSI_MATCHED_NAME"],
                match_score=float(row["GSI_MATCH_SCORE"]), matched_fields=split(row["GSI_MATCHED_FIELDS"]),
            ),
            history=History(
                transfers_30d=int(row["TRANSFERS_30D"]),
                total_30d_usd=float(row["TOTAL_30D_USD"]),
                avg_amount_usd=float(row["AVG_AMOUNT_USD"]),
            ),
            flags=split(row["FLAGS"]),
        )


def get_repository() -> CaseRepository:
    if settings.SNOWFLAKE_MODE == "real":
        return SnowflakeCaseRepository()
    return MockCaseRepository()
