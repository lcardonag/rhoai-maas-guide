import re
import sqlite3
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator, Literal

MemberType = Literal["user", "group"]
EnforcementState = Literal["ok", "throttled", "free_only", "exhausted"]


@dataclass
class BudgetEntity:
    entity_id: str
    display_name: str
    member_type: MemberType
    member_ref: str
    maas_subscription: str
    billing_backend: str
    lago_external_id: str
    lago_customer_id: str | None
    lago_subscription_external_id: str | None
    catalog_profile: str
    enforcement_state: EnforcementState
    monthly_budget_credits: float
    created_at: str


def slugify_member_ref(member_ref: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", member_ref.lower()).strip("-")
    if not slug:
        raise ValueError("member_ref must contain at least one alphanumeric character")
    return slug[:63]


def entity_id_for(member_ref: str) -> str:
    return f"be:{slugify_member_ref(member_ref)}"


def subscription_name_for(member_ref: str) -> str:
    return f"budget-{slugify_member_ref(member_ref)}"


class EntityStore:
    def __init__(self, path: str) -> None:
        self.path = path
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        self._init_db()

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.path)
        conn.row_factory = sqlite3.Row
        return conn

    def _init_db(self) -> None:
        with self._connect() as conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS budget_entities (
                    entity_id TEXT PRIMARY KEY,
                    display_name TEXT NOT NULL,
                    member_type TEXT NOT NULL,
                    member_ref TEXT NOT NULL,
                    maas_subscription TEXT NOT NULL UNIQUE,
                    billing_backend TEXT NOT NULL DEFAULT 'lago',
                    lago_external_id TEXT NOT NULL,
                    lago_customer_id TEXT,
                    lago_subscription_external_id TEXT,
                    catalog_profile TEXT NOT NULL,
                    enforcement_state TEXT NOT NULL,
                    monthly_budget_credits REAL NOT NULL,
                    created_at TEXT NOT NULL
                )
                """
            )
            cols = {row[1] for row in conn.execute("PRAGMA table_info(budget_entities)")}
            if "billing_backend" not in cols:
                conn.execute(
                    "ALTER TABLE budget_entities ADD COLUMN billing_backend TEXT NOT NULL DEFAULT 'lago'"
                )
            conn.commit()

    @contextmanager
    def session(self) -> Iterator[sqlite3.Connection]:
        conn = self._connect()
        try:
            yield conn
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()

    def _row_to_entity(self, row: sqlite3.Row) -> BudgetEntity:
        data = dict(row)
        data.setdefault("billing_backend", "lago")
        return BudgetEntity(**data)

    def insert(self, entity: BudgetEntity) -> None:
        with self.session() as conn:
            conn.execute(
                """
                INSERT INTO budget_entities (
                    entity_id, display_name, member_type, member_ref,
                    maas_subscription, billing_backend, lago_external_id, lago_customer_id,
                    lago_subscription_external_id, catalog_profile,
                    enforcement_state, monthly_budget_credits, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    entity.entity_id,
                    entity.display_name,
                    entity.member_type,
                    entity.member_ref,
                    entity.maas_subscription,
                    entity.billing_backend,
                    entity.lago_external_id,
                    entity.lago_customer_id,
                    entity.lago_subscription_external_id,
                    entity.catalog_profile,
                    entity.enforcement_state,
                    entity.monthly_budget_credits,
                    entity.created_at,
                ),
            )

    def list_all(self) -> list[BudgetEntity]:
        with self.session() as conn:
            rows = conn.execute("SELECT * FROM budget_entities ORDER BY created_at").fetchall()
        return [self._row_to_entity(r) for r in rows]

    def get(self, entity_id: str) -> BudgetEntity | None:
        with self.session() as conn:
            row = conn.execute(
                "SELECT * FROM budget_entities WHERE entity_id = ?", (entity_id,)
            ).fetchone()
        return self._row_to_entity(row) if row else None

    def get_by_subscription(self, maas_subscription: str) -> BudgetEntity | None:
        with self.session() as conn:
            row = conn.execute(
                "SELECT * FROM budget_entities WHERE maas_subscription = ?",
                (maas_subscription,),
            ).fetchone()
        return self._row_to_entity(row) if row else None

    def update_enforcement(self, entity_id: str, state: EnforcementState) -> None:
        with self.session() as conn:
            conn.execute(
                "UPDATE budget_entities SET enforcement_state = ? WHERE entity_id = ?",
                (state, entity_id),
            )

    def update_lago_ids(
        self,
        entity_id: str,
        customer_id: str | None,
        subscription_external_id: str | None,
    ) -> None:
        with self.session() as conn:
            conn.execute(
                """
                UPDATE budget_entities
                SET lago_customer_id = ?, lago_subscription_external_id = ?
                WHERE entity_id = ?
                """,
                (customer_id, subscription_external_id, entity_id),
            )
