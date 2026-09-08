from __future__ import annotations

import copy
import logging
from typing import Any

import yaml
from kubernetes import client, config
from kubernetes.client.rest import ApiException

from maas_billing.config import settings

log = logging.getLogger(__name__)

MAAS_API = "maas.opendatahub.io/v1alpha1"


def load_k8s() -> None:
    try:
        config.load_incluster_config()
    except config.ConfigException:
        config.load_kube_config()


def _custom_objects() -> client.CustomObjectsApi:
    load_k8s()
    return client.CustomObjectsApi()


def _core() -> client.CoreV1Api:
    load_k8s()
    return client.CoreV1Api()


def load_tier_model_refs(profile: str, tier: str) -> list[dict[str, Any]]:
    cm = _core().read_namespaced_config_map(
        settings.tier_templates_configmap,
        settings.tier_templates_namespace,
    )
    key = f"{profile}.{tier}.yaml"
    raw = (cm.data or {}).get(key)
    if not raw:
        raise KeyError(f"tier template missing: {key}")
    doc = yaml.safe_load(raw) or {}
    return doc.get("modelRefs") or []


def build_subscription_body(
    name: str,
    display_name: str,
    member_type: str,
    member_ref: str,
    model_refs: list[dict[str, Any]],
    priority: int = 20,
) -> dict[str, Any]:
    owner: dict[str, Any] = {"users": [], "groups": []}
    if member_type == "user":
        owner["users"] = [member_ref]
    else:
        owner["groups"] = [member_ref]
    return {
        "apiVersion": MAAS_API,
        "kind": "MaaSSubscription",
        "metadata": {
            "name": name,
            "namespace": settings.maas_subscription_namespace,
            "annotations": {
                "openshift.io/display-name": display_name,
                "openshift.io/description": f"Lago budget entity subscription {name}",
                "maas-billing/entity": "true",
            },
        },
        "spec": {
            "owner": owner,
            "modelRefs": copy.deepcopy(model_refs),
            "priority": priority,
        },
    }


def build_auth_policy_body(
    subscription_name: str,
    display_name: str,
    member_type: str,
    member_ref: str,
    model_refs: list[dict[str, Any]],
) -> dict[str, Any]:
    subjects: dict[str, Any] = {"users": [], "groups": []}
    if member_type == "user":
        subjects["users"] = [member_ref]
    else:
        subjects["groups"] = [member_ref]
    policy_name = f"{subscription_name}-access"
    refs = [{"name": m["name"], "namespace": m["namespace"]} for m in model_refs]
    return {
        "apiVersion": MAAS_API,
        "kind": "MaaSAuthPolicy",
        "metadata": {
            "name": policy_name,
            "namespace": settings.maas_subscription_namespace,
            "annotations": {
                "openshift.io/display-name": f"{display_name} access",
                "openshift.io/description": f"Access policy for {subscription_name}",
            },
        },
        "spec": {
            "modelRefs": refs,
            "subjects": subjects,
        },
    }


def apply_maas_governance(
    subscription_name: str,
    display_name: str,
    member_type: str,
    member_ref: str,
    tier: str,
    catalog_profile: str,
) -> None:
    model_refs = load_tier_model_refs(catalog_profile, tier)
    api = _custom_objects()
    ns = settings.maas_subscription_namespace
    sub = build_subscription_body(
        subscription_name, display_name, member_type, member_ref, model_refs
    )
    policy = build_auth_policy_body(
        subscription_name, display_name, member_type, member_ref, model_refs
    )
    for body in (sub, policy):
        kind = body["kind"]
        name = body["metadata"]["name"]
        plural = _plural(kind)
        try:
            api.create_namespaced_custom_object(
                group="maas.opendatahub.io",
                version="v1alpha1",
                namespace=ns,
                plural=plural,
                body=body,
            )
        except ApiException as exc:
            if exc.status != 409:
                raise
            api.replace_namespaced_custom_object(
                group="maas.opendatahub.io",
                version="v1alpha1",
                namespace=ns,
                plural=plural,
                name=name,
                body=body,
            )
        log.info("applied %s/%s", kind, name)


def patch_subscription_tier(
    subscription_name: str,
    tier: str,
    catalog_profile: str,
) -> None:
    model_refs = load_tier_model_refs(catalog_profile, tier)
    api = _custom_objects()
    ns = settings.maas_subscription_namespace
    body = {
        "apiVersion": MAAS_API,
        "kind": "MaaSSubscription",
        "metadata": {"name": subscription_name, "namespace": ns},
        "spec": {"modelRefs": model_refs},
    }
    try:
        existing = api.get_namespaced_custom_object(
            group="maas.opendatahub.io",
            version="v1alpha1",
            namespace=ns,
            plural="maassubscriptions",
            name=subscription_name,
        )
    except ApiException as exc:
        if exc.status != 404:
            raise
        existing = None
    if existing:
        body["metadata"] = existing.get("metadata", body["metadata"])
        body["spec"] = {**(existing.get("spec") or {}), **body["spec"]}
        api.replace_namespaced_custom_object(
            group="maas.opendatahub.io",
            version="v1alpha1",
            namespace=ns,
            plural="maassubscriptions",
            name=subscription_name,
            body=body,
        )
    else:
        raise KeyError(subscription_name)
    log.info("patched MaaSSubscription/%s tier=%s", subscription_name, tier)


def _plural(kind: str) -> str:
    if kind == "MaaSSubscription":
        return "maassubscriptions"
    if kind == "MaaSAuthPolicy":
        return "maasauthpolicies"
    raise ValueError(kind)
