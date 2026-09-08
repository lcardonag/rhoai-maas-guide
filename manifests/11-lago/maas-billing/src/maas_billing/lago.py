from __future__ import annotations

import logging
from typing import Any

import httpx

from maas_billing.config import settings

log = logging.getLogger(__name__)


class LagoClient:
    def __init__(self, base_url: str | None = None, api_key: str | None = None) -> None:
        self.base_url = (base_url or settings.lago_api_url).rstrip("/")
        self.api_key = api_key if api_key is not None else settings.lago_api_key

    def _headers(self) -> dict[str, str]:
        if not self.api_key:
            raise RuntimeError("LAGO_API_KEY is not set")
        return {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json",
        }

    def _request(self, method: str, path: str, **kwargs: Any) -> dict[str, Any]:
        url = f"{self.base_url}{path}"
        with httpx.Client(timeout=30.0) as client:
            resp = client.request(method, url, headers=self._headers(), **kwargs)
        if resp.status_code >= 400:
            raise RuntimeError(f"Lago {method} {path} failed: HTTP {resp.status_code} {resp.text}")
        if not resp.content:
            return {}
        return resp.json()

    def create_customer(self, external_id: str, name: str) -> dict[str, Any]:
        payload = {"customer": {"external_id": external_id, "name": name}}
        data = self._request("POST", "/api/v1/customers", json=payload)
        return data.get("customer", data)

    def create_wallet(
        self,
        external_customer_id: str,
        paid_credits: float,
        name: str,
        currency: str = "USD",
    ) -> dict[str, Any]:
        payload = {
            "wallet": {
                "name": name,
                "rate_amount": "1.0",
                "paid_credits": str(paid_credits),
                "currency": currency,
                "external_customer_id": external_customer_id,
            }
        }
        data = self._request("POST", "/api/v1/wallets", json=payload)
        return data.get("wallet", data)

    def assign_plan_subscription(
        self,
        external_customer_id: str,
        plan_code: str,
        external_subscription_id: str,
    ) -> dict[str, Any]:
        payload = {
            "subscription": {
                "external_customer_id": external_customer_id,
                "plan_code": plan_code,
                "external_id": external_subscription_id,
            }
        }
        data = self._request("POST", "/api/v1/subscriptions", json=payload)
        return data.get("subscription", data)

    def send_usage_event(
        self,
        transaction_id: str,
        external_subscription_id: str,
        code: str,
        properties: dict[str, Any],
        timestamp: int | None = None,
    ) -> None:
        import time

        event: dict[str, Any] = {
            "transaction_id": transaction_id,
            "external_subscription_id": external_subscription_id,
            "code": code,
            "properties": properties,
        }
        if timestamp is not None:
            event["timestamp"] = timestamp
        else:
            event["timestamp"] = int(time.time())
        self._request("POST", "/api/v1/events", json={"event": event})

    def wallet_usage_percent(self, external_customer_id: str) -> float | None:
        """Return consumed % of prepaid wallet credits (0-100+), or None if unavailable."""
        try:
            data = self._request(
                "GET",
                "/api/v1/wallets",
                params={"external_customer_id": external_customer_id},
            )
        except RuntimeError as exc:
            log.warning("wallet lookup failed for %s: %s", external_customer_id, exc)
            return None
        wallets = data.get("wallets") or []
        if not wallets:
            return None
        wallet = wallets[0]
        paid = float(wallet.get("paid_credits") or wallet.get("credits_balance") or 0)
        balance = float(wallet.get("balance") or wallet.get("credits_balance") or 0)
        if paid <= 0:
            return None
        consumed = max(0.0, paid - balance)
        return (consumed / paid) * 100.0
