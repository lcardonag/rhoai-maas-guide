from __future__ import annotations

import hashlib
import logging
import time
from pathlib import Path

import httpx

from maas_billing.config import settings
from maas_billing.lago import LagoClient
from maas_billing.openmeter import OpenMeterClient

log = logging.getLogger(__name__)


def _prometheus_auth_header() -> dict[str, str]:
    token_path = Path(settings.prometheus_service_account_token_path)
    if not token_path.is_file():
        return {}
    token = token_path.read_text(encoding="utf-8").strip()
    if not token:
        return {}
    return {"Authorization": f"Bearer {token}"}


def _query_prometheus(promql: str) -> list[dict]:
    url = f"{settings.prometheus_url.rstrip('/')}/api/v1/query"
    headers = _prometheus_auth_header()
    with httpx.Client(timeout=60.0, verify=settings.prometheus_tls_verify) as client:
        resp = client.get(url, params={"query": promql}, headers=headers)
    resp.raise_for_status()
    data = resp.json()
    if data.get("status") != "success":
        raise RuntimeError(f"prometheus query failed: {data}")
    return data.get("data", {}).get("result", [])


def _transaction_id(subscription: str, user: str, model: str, window: str) -> str:
    raw = f"{subscription}|{user}|{model}|{window}"
    return "maas-" + hashlib.sha256(raw.encode()).hexdigest()[:32]


def _fetch_entities_by_subscription() -> dict[str, dict]:
    url = f"{settings.billing_api_url.rstrip('/')}/api/v1/entities"
    with httpx.Client(timeout=30.0) as client:
        resp = client.get(url)
    resp.raise_for_status()
    entities = resp.json()
    return {e["maas_subscription"]: e for e in entities}


def _report_lago(
    lago: LagoClient,
    entity: dict,
    subscription: str,
    user: str,
    model: str,
    tokens: int,
    txn: str,
) -> None:
    sub_ext = entity.get("lago_subscription_external_id")
    if not sub_ext:
        return
    lago.send_usage_event(
        transaction_id=txn,
        external_subscription_id=sub_ext,
        code=settings.lago_billable_metric_code,
        properties={
            "subscription": subscription,
            "user": user,
            "model": model,
            "tokens": tokens,
        },
    )


def _report_openmeter(
    om: OpenMeterClient,
    entity: dict,
    subscription: str,
    user: str,
    model: str,
    tokens: int,
    txn: str,
) -> None:
    subject = entity.get("entity_id") or entity.get("lago_external_id")
    if not subject:
        return
    om.send_usage_event(
        event_id=txn,
        subject=subject,
        event_type=settings.openmeter_event_type,
        data={
            "subscription": subscription,
            "user": user,
            "model": model,
            "input_tokens": str(tokens),
            "output_tokens": "0",
        },
    )


def run_reporter() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    backend = settings.billing_backend.lower()
    lago = LagoClient() if backend == "lago" else None
    openmeter = OpenMeterClient() if backend == "openmeter" else None
    log.info(
        "usage-reporter started backend=%s interval=%ss promql=%s prometheus=%s",
        backend,
        settings.reporter_interval_seconds,
        settings.reporter_promql,
        settings.prometheus_url,
    )
    while True:
        window = str(int(time.time() // settings.reporter_interval_seconds))
        try:
            by_sub = _fetch_entities_by_subscription()
            results = _query_prometheus(settings.reporter_promql)
            for series in results:
                metric = series.get("metric", {})
                subscription = metric.get("subscription") or ""
                if not subscription.startswith("budget-"):
                    continue
                entity = by_sub.get(subscription)
                if not entity:
                    continue
                value = float(series.get("value", [0, "0"])[1])
                if value <= 0:
                    continue
                user = metric.get("user") or "unknown"
                model = metric.get("model") or "unknown"
                tokens = int(value * settings.reporter_tokens_per_request)
                txn = _transaction_id(subscription, user, model, window)
                entity_backend = (entity.get("billing_backend") or backend).lower()
                if entity_backend == "openmeter" and openmeter:
                    _report_openmeter(openmeter, entity, subscription, user, model, tokens, txn)
                elif lago:
                    _report_lago(lago, entity, subscription, user, model, tokens, txn)
                log.info("reported %s tokens for %s (txn=%s)", tokens, subscription, txn)
        except Exception as exc:
            log.exception("reporter cycle failed: %s", exc)
        time.sleep(settings.reporter_interval_seconds)
