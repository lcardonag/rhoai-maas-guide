import sys

from maas_billing.api_app import run_api
from maas_billing.enforcer import run_enforcer
from maas_billing.reporter import run_reporter


def main() -> None:
    cmd = sys.argv[1] if len(sys.argv) > 1 else "api"
    if cmd == "api":
        run_api()
    elif cmd == "reporter":
        run_reporter()
    elif cmd == "enforcer":
        run_enforcer()
    else:
        raise SystemExit(f"unknown command: {cmd} (expected api, reporter, enforcer)")


if __name__ == "__main__":
    main()
