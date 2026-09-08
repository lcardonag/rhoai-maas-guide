from __future__ import annotations

import logging
import uuid
from datetime import datetime, timezone
from typing import Any

import httpx

from maas_billing.config import settings

log = logging.getLogger(__name__)


class OpenMeterClient:
    def __init__(self, base_url: str | None = None, api_key: str | None = None) -> None:
        self.base_url = (base_url or settings.openmeter_url).rstrip("/")
        self.api_key = api_key if api_key is not None else settings.openmeter_api_key

    def _headers(self, cloud_event: bool = False) -> dict[str, str]:
        headers = {}
        if cloud_event:
            headers["Content-Type"] = "application/cloudevents+json"
        else:
            headers["Content-Type"] = "application/json"
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        return headers

    def _request(self, method: str, path: str, **kwargs: Any) -> dict[str, Any]:
        url = f"{self.base_url}{path}"
        with httpx.Client(timeout=30.0) as client:
            resp = client.request(method, url, headers=self._headers(), **kwargs)
        if resp.status_code >= 400:
            raise RuntimeError(f"OpenMeter {method} {path} failed: HTTP {resp.status_code} {resp.text}")
        if not resp.content:
            return {}
        return resp.json()

    def create_customer(self, key: str, name: str) -> dict[str, Any]:
        payload = {"key": key, "name": name, "usageAttribution": {"subjectKeys": [key]}}
        try:
            data = self._request("POST", "/api/v1/customers", json=payload)
        except RuntimeError as exc:
            if "409" not in str(exc):
                raise
            log.info("OpenMeter customer %s already exists — reusing", key)
            data = self._request("GET", f"/api/v1/customers/{key}")
        return data.get("customer", data)

    def create_metered_entitlement(self, customer_key: str, feature_key: str, issue_after_reset: int) -> None:
        # v1 /customers/.../entitlements returns 404 on current OSS builds; use customer v2 API.
        payload = {
            "type": "metered",
            "featureKey": feature_key,
            "usagePeriod": {"interval": "MONTH"},
            "issueAfterReset": issue_after_reset,
        }
        try:
            self._request(
                "POST",
                f"/api/v2/customers/{customer_key}/entitlements",
                json=payload,
            )
        except RuntimeError as exc:
            if "409" in str(exc):
                log.info("OpenMeter entitlement already exists for %s/%s", customer_key, feature_key)
                return
            raise

    def create_grant(self, customer_key: str, feature_key: str, amount: float) -> None:
        # Optional top-up grant; cannot combine with issueAfterReset on the same entitlement.
        payload = {
            "amount": amount,
            "priority": 1,
            "effectiveAt": datetime.now(timezone.utc).isoformat(),
            "expiration": {"duration": "MONTH", "count": 1},
        }
        self._request(
            "POST",
            f"/api/v2/customers/{customer_key}/entitlements/{feature_key}/grants",
            json=payload,
        )

    def send_usage_event(
        self,
        event_id: str,
        subject: str,
        event_type: str,
        data: dict[str, Any],
    ) -> None:
        event = {
            "specversion": "1.0",
            "type": event_type,
            "id": event_id,
            "source": "rhoai-maas-guide/usage-reporter",
            "subject": subject,
            "time": datetime.now(timezone.utc).isoformat(),
            "data": data,
        }
        url = f"{self.base_url}/api/v1/events"
        with httpx.Client(timeout=30.0) as client:
            resp = client.post(url, headers=self._headers(cloud_event=True), json=event)
        if resp.status_code >= 400:
            raise RuntimeError(f"OpenMeter event ingest failed: HTTP {resp.status_code} {resp.text}")

    def usage_percent(self, customer_key: str, grant: float) -> float | None:
        if grant <= 0:
            return None
        feature = settings.openmeter_feature_key
        for path in (
            f"/api/v2/customers/{customer_key}/entitlements/{feature}/value",
            f"/api/v1/customers/{customer_key}/entitlements/{feature}/value",
        ):
            try:
                data = self._request("GET", path)
                break
            except RuntimeError as exc:
                log.warning("entitlement value lookup failed for %s via %s: %s", customer_key, path, exc)
                data = None
        if not data:
            return None
        body = data.get("value", data)
        if isinstance(body, dict):
            if body.get("hasAccess") is False:
                return 100.0
            usage = float(body.get("usage") or body.get("balanceUsage") or 0)
        else:
            usage = float(body or 0)
        return min(100.0, (usage / grant) * 100.0)

    @staticmethod
    def new_event_id() -> str:
        return f"maas-{uuid.uuid4().hex[:24]}"
