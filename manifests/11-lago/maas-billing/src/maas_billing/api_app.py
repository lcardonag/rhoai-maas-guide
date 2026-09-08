from __future__ import annotations

import logging
from dataclasses import asdict
from typing import Literal

import uvicorn
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

from maas_billing.config import settings
from maas_billing.db import EntityStore
from maas_billing.entities import EntityService
from maas_billing.k8s_maas import load_tier_model_refs

log = logging.getLogger(__name__)

app = FastAPI(title="maas-billing-api", version="0.1.0")
_service: EntityService | None = None


def get_service() -> EntityService:
    global _service
    if _service is None:
        _service = EntityService()
    return _service


class CreateEntityRequest(BaseModel):
    display_name: str = Field(min_length=1, max_length=128)
    member_type: Literal["user", "group"]
    member_ref: str = Field(min_length=1, max_length=128)
    monthly_budget_credits: float = Field(gt=0)
    catalog_profile: str | None = None


class EntityResponse(BaseModel):
    entity_id: str
    display_name: str
    member_type: str
    member_ref: str
    maas_subscription: str
    billing_backend: str
    lago_external_id: str
    lago_customer_id: str | None
    lago_subscription_external_id: str | None
    catalog_profile: str
    enforcement_state: str
    monthly_budget_credits: float
    created_at: str


def to_response(entity) -> EntityResponse:
    data = asdict(entity)
    return EntityResponse(**data)


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok", "billing_backend": settings.billing_backend}


@app.get("/api/v1/catalog-profiles")
def catalog_profiles() -> dict[str, list[str]]:
    store = EntityStore(settings.database_path)
    _ = store  # ensure DB path writable
    tiers = ["full", "throttled", "free_only", "exhausted"]
    return {"profiles": [settings.catalog_profile], "tiers": tiers}


@app.get("/api/v1/catalog-profiles/{profile}/{tier}")
def catalog_profile_tier(profile: str, tier: str) -> dict:
    try:
        refs = load_tier_model_refs(profile, tier)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    return {"profile": profile, "tier": tier, "modelRefs": refs}


@app.post("/api/v1/entities", response_model=EntityResponse, status_code=201)
def create_entity(body: CreateEntityRequest) -> EntityResponse:
    try:
        entity = get_service().create_entity(
            display_name=body.display_name,
            member_type=body.member_type,
            member_ref=body.member_ref,
            monthly_budget_credits=body.monthly_budget_credits,
            catalog_profile=body.catalog_profile,
        )
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return to_response(entity)


@app.get("/api/v1/entities", response_model=list[EntityResponse])
def list_entities() -> list[EntityResponse]:
    return [to_response(e) for e in get_service().list_entities()]


@app.get("/api/v1/entities/{entity_id}", response_model=EntityResponse)
def get_entity(entity_id: str) -> EntityResponse:
    entity = get_service().get_entity(entity_id)
    if not entity:
        raise HTTPException(status_code=404, detail="entity not found")
    return to_response(entity)


@app.post("/api/v1/entities/{entity_id}/reset", response_model=EntityResponse)
def reset_entity(entity_id: str) -> EntityResponse:
    try:
        entity = get_service().reset_entity(entity_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="entity not found") from exc
    return to_response(entity)


@app.post("/api/v1/enforcer/tick")
def enforcer_tick() -> dict:
    updated: list[dict[str, str]] = []
    service = get_service()
    for entity in service.list_entities():
        new_state = service.evaluate_entity(entity)
        if new_state:
            updated.append({"entity_id": entity.entity_id, "state": new_state})
    return {"updated": updated}


def run_api() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    uvicorn.run(app, host=settings.api_host, port=settings.api_port, log_level="info")
