from __future__ import annotations

import logging
from datetime import datetime, timezone
from typing import Literal

from maas_billing.config import settings
from maas_billing.db import (
    BudgetEntity,
    EntityStore,
    entity_id_for,
    subscription_name_for,
)
from maas_billing.k8s_maas import apply_maas_governance, patch_subscription_tier
from maas_billing.lago import LagoClient
from maas_billing.openmeter import OpenMeterClient

log = logging.getLogger(__name__)

MemberType = Literal["user", "group"]
EnforcementState = Literal["ok", "throttled", "free_only", "exhausted"]

TIER_BY_STATE: dict[EnforcementState, str] = {
    "ok": "full",
    "throttled": "throttled",
    "free_only": "free_only",
    "exhausted": "exhausted",
}


def tier_for_percent(percent: float, current: EnforcementState) -> EnforcementState | None:
    if percent >= 100 and current != "exhausted":
        return "exhausted"
    if percent >= 99 and current not in ("free_only", "exhausted"):
        return "free_only"
    if percent >= 95 and current == "ok":
        return "throttled"
    if percent < 95 and current != "ok":
        return "ok"
    return None


class EntityService:
    def __init__(
        self,
        store: EntityStore | None = None,
        lago: LagoClient | None = None,
        openmeter: OpenMeterClient | None = None,
    ) -> None:
        self.store = store or EntityStore(settings.database_path)
        self.backend = settings.billing_backend.lower()
        self.lago = lago or LagoClient()
        self.openmeter = openmeter or OpenMeterClient()

    def create_entity(
        self,
        display_name: str,
        member_type: MemberType,
        member_ref: str,
        monthly_budget_credits: float,
        catalog_profile: str | None = None,
    ) -> BudgetEntity:
        profile = catalog_profile or settings.catalog_profile
        eid = entity_id_for(member_ref)
        sub_name = subscription_name_for(member_ref)
        if self.store.get(eid):
            raise ValueError(f"entity already exists: {eid}")
        if self.store.get_by_subscription(sub_name):
            raise ValueError(f"subscription already enrolled: {sub_name}")

        customer_id: str | None = None
        sub_ext_id = sub_name

        if self.backend == "openmeter":
            customer = self.openmeter.create_customer(key=eid, name=display_name)
            customer_id = customer.get("id")
            grant = int(monthly_budget_credits)
            self.openmeter.create_metered_entitlement(eid, settings.openmeter_feature_key, grant)
            sub_ext_id = eid
        else:
            customer = self.lago.create_customer(external_id=eid, name=display_name)
            customer_id = str(customer.get("lago_id") or customer.get("id") or "") or None
            try:
                self.lago.assign_plan_subscription(
                    external_customer_id=eid,
                    plan_code=settings.lago_plan_code,
                    external_subscription_id=sub_ext_id,
                )
            except RuntimeError as exc:
                log.warning("plan subscription skipped (%s); using wallet fallback", exc)
                self.lago.create_wallet(
                    external_customer_id=eid,
                    paid_credits=monthly_budget_credits,
                    name=f"{display_name} wallet",
                )

        apply_maas_governance(
            subscription_name=sub_name,
            display_name=display_name,
            member_type=member_type,
            member_ref=member_ref,
            tier="full",
            catalog_profile=profile,
        )

        entity = BudgetEntity(
            entity_id=eid,
            display_name=display_name,
            member_type=member_type,
            member_ref=member_ref,
            maas_subscription=sub_name,
            billing_backend=self.backend,
            lago_external_id=eid,
            lago_customer_id=customer_id,
            lago_subscription_external_id=sub_ext_id,
            catalog_profile=profile,
            enforcement_state="ok",
            monthly_budget_credits=monthly_budget_credits,
            created_at=datetime.now(timezone.utc).isoformat(),
        )
        self.store.insert(entity)
        return entity

    def list_entities(self) -> list[BudgetEntity]:
        return self.store.list_all()

    def get_entity(self, entity_id: str) -> BudgetEntity | None:
        return self.store.get(entity_id)

    def reset_entity(self, entity_id: str) -> BudgetEntity:
        entity = self.store.get(entity_id)
        if not entity:
            raise KeyError(entity_id)
        self.apply_enforcement(entity, "ok")
        return self.store.get(entity_id)  # type: ignore[return-value]

    def apply_enforcement(self, entity: BudgetEntity, state: EnforcementState) -> None:
        tier = TIER_BY_STATE[state]
        patch_subscription_tier(entity.maas_subscription, tier, entity.catalog_profile)
        self.store.update_enforcement(entity.entity_id, state)
        log.info("entity %s enforcement -> %s", entity.entity_id, state)

    def evaluate_entity(self, entity: BudgetEntity) -> EnforcementState | None:
        percent: float | None
        if entity.billing_backend == "openmeter":
            percent = self.openmeter.usage_percent(entity.entity_id, entity.monthly_budget_credits)
        else:
            percent = self.lago.wallet_usage_percent(entity.lago_external_id)
        if percent is None:
            return None
        new_state = tier_for_percent(percent, entity.enforcement_state)
        if new_state and new_state != entity.enforcement_state:
            self.apply_enforcement(entity, new_state)
            return new_state
        return None
