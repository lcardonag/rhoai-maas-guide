from __future__ import annotations

import logging
import time

import httpx

from maas_billing.config import settings

log = logging.getLogger(__name__)


def run_enforcer() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    url = f"{settings.billing_api_url.rstrip('/')}/api/v1/enforcer/tick"
    log.info("budget-enforcer started interval=%ss api=%s", settings.enforcer_interval_seconds, url)
    while True:
        try:
            with httpx.Client(timeout=120.0) as client:
                resp = client.post(url)
            resp.raise_for_status()
            updated = resp.json().get("updated", [])
            if updated:
                log.info("enforcer tick updated %s", updated)
        except Exception as exc:
            log.exception("enforcer cycle failed: %s", exc)
        time.sleep(settings.enforcer_interval_seconds)
