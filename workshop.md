# Workshop Guide

This guide is for **workshop participants**. You only need to complete two steps before the session: deploy infrastructure and upload data. The CI/CD pipelines (training, model promotion, and deployment) will be run together during the workshop.

For full context on the architecture, design decisions, and project structure, see the main [README.md](README.md).

> **What you're skipping:** GitHub OIDC setup, service principal creation, federated credentials, and GitHub Environment configuration. The workshop facilitator will walk through the CI/CD workflows live.

---

## Prerequisites

See the main [README.md](README.md#prerequisites) for full details. For the workshop you need:

- Azure subscription with **Contributor** + **Role Based Access Control Administrator** at the subscription level
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) with the `ml` extension (`az extension add -n ml`)
- Python 3.13+
- **CPU quota** in Sweden Central: minimum **24 vCPU** of `Standard DSv2 Family`. [Request increase](https://learn.microsoft.com/azure/quotas/per-vm-quota-requests) if needed.

---

## Step 1 — Deploy Infrastructure

Follow [Deploy Infrastructure](README.md#1-deploy-infrastructure) from the main README, but run it locally with the Azure CLI instead of GitHub Actions:

```bash
az login
az account set --subscription "<YOUR_SUBSCRIPTION_ID>"
```

Deploy in order — **shared → dev → test → prod**:

```bash
# 1. Shared (ML Registry)
az deployment sub create \
  --location swedencentral \
  --template-file infra/shared.bicep \
  --parameters infra/parameters/shared.bicepparam

# Grab IDs for subsequent deployments
REGISTRY_ID=$(az ml registry show --name readmit-registry --resource-group rg-readmit-shared --query id -o tsv)
USER_ID=$(az ad signed-in-user show --query id -o tsv)

# 2. Dev
az deployment sub create \
  --location swedencentral \
  --template-file infra/main.bicep \
  --parameters infra/parameters/dev.bicepparam \
  --parameters mlRegistryId="$REGISTRY_ID" userPrincipalId="$USER_ID"

# 3. Test
az deployment sub create \
  --location swedencentral \
  --template-file infra/main.bicep \
  --parameters infra/parameters/test.bicepparam \
  --parameters mlRegistryId="$REGISTRY_ID" userPrincipalId="$USER_ID"

# 4. Prod
az deployment sub create \
  --location swedencentral \
  --template-file infra/main.bicep \
  --parameters infra/parameters/prod.bicepparam \
  --parameters mlRegistryId="$REGISTRY_ID" userPrincipalId="$USER_ID"
```

---

## Step 2 — Upload Training Data

Follow [Upload Training Data](README.md#2-upload-training-data) from the main README.

First, get your workspace names (they include an auto-generated unique suffix):

```bash
# List workspace names per environment
az ml workspace list -g rg-readmit-dev --query "[].name" -o tsv
az ml workspace list -g rg-readmit-test --query "[].name" -o tsv
```

Then upload:

```bash
pip install -r requirements.txt

python scripts/generate_and_upload_data.py -g rg-readmit-dev -w <dev-workspace-name>
python scripts/generate_and_upload_data.py -g rg-readmit-test -w <test-workspace-name> --num-samples 50000
```

> **Note:** Workspace names follow the pattern `readmit-{env}-<suffix>-ws` (e.g. `readmit-dev-abc123-ws`). The suffix is auto-generated from the resource group ID.

---

## What Happens During the Workshop

With infrastructure deployed and data uploaded, the facilitator will walk through:

1. **`multi-env-train.yml`** (manual dispatch) — registers components locally in dev → validates pipeline on dev (synthetic data) → approval gate → promotes components + environment to shared registry
2. **`multi-env-deploy.yml`** (auto-triggers on train success, or manual dispatch) — retrains on test (full data) → deploys to test endpoint → integration tests (schema + latency) → approval gate → promotes model to shared registry → deploys to prod

> **Note:** You must run `train.yml` at least once before `deploy.yml` — it needs a trained model to deploy.

These are the CI/CD workflows described in [Run Workflows](README.md#3-run-workflows).

---

## Troubleshooting

See the main [README.md](README.md) for detailed explanations. Quick fixes:

| Symptom | Fix |
|---------|-----|
| "Authorization failed" in AML Studio | Ensure `userPrincipalId` was set during deployment |
| Quota exceeded | [Request vCPU increase](https://learn.microsoft.com/azure/quotas/per-vm-quota-requests) for `Standard DSv2 Family` in Sweden Central |
| `readmission-raw-data` not found | Re-run the upload script (Step 2) |
| Role assignment already exists | Set `skipRoleAssignments = true` in the `.bicepparam` file and redeploy |
