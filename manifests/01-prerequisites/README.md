# Phase 1: Prerequisites

Operator subscriptions: RHOAI, RHCL (Connectivity Link), cert-manager, LWS.

Full documentation: https://rh-aiservices-bu.github.io/rhoai-maas-guide/modules/main/01-prerequisites.html

```bash
oc apply -k manifests/01-prerequisites/operators/
```

## Before you run the script

If OpenShift AI is **already installed from the GUI**, check for a single `OperatorGroup` in `redhat-ods-operator`. Running Phase 1 again can create a duplicate and break the `rhods-operator` CSV (`TooManyOperatorGroups`). See Phase 4 troubleshooting in the full guide.
