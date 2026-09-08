from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    # Shared
    billing_backend: str = "lago"  # lago | openmeter
    maas_subscription_namespace: str = "models-as-a-service"
    tier_templates_configmap: str = "maas-billing-tier-templates"
    tier_templates_namespace: str = "maas-billing"
    catalog_profile: str = "standard"
    database_path: str = "/data/entities.db"

    # Lago
    lago_api_url: str = "http://lago-api.lago.svc:3000"
    lago_api_key: str = ""
    lago_billable_metric_code: str = "llm_tokens"
    lago_plan_code: str = "maas-standard"

    # OpenMeter
    openmeter_url: str = "http://openmeter.openmeter.svc"
    openmeter_api_key: str = ""
    openmeter_feature_key: str = "llm_tokens"
    openmeter_event_type: str = "maas.tokens.consumed"

    # API
    api_host: str = "0.0.0.0"
    api_port: int = 8080

    # usage-reporter (OpenShift Thanos requires HTTPS + projected SA token)
    prometheus_url: str = "https://thanos-querier.openshift-monitoring.svc:9091"
    prometheus_service_account_token_path: str = (
        "/var/run/secrets/kubernetes.io/serviceaccount/token"
    )
    prometheus_tls_verify: bool = False
    reporter_interval_seconds: int = 120
    reporter_promql: str = (
        'sum by (subscription, user, model) ('
        'increase(authorized_hits{subscription=~"budget-.*"}[2m]))'
    )
    reporter_tokens_per_request: int = 1000

    # budget-enforcer / usage-reporter (shared API)
    billing_api_url: str = "http://maas-billing-api.maas-billing.svc:8080"
    enforcer_interval_seconds: int = 60


settings = Settings()
