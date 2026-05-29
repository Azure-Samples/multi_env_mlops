# Multi-Environment MLOps for Healthcare

Predict 30-day hospital readmission risk with Bicep IaC, three-environment model promotion (dev → test → prod), a shared ML Registry, and identity-based auth on Azure Machine Learning.

## Problem Statement

Hospital readmissions within 30 days are a key quality metric in healthcare — they indicate gaps in care transitions, drive significant costs, and are subject to regulatory penalties. Building a predictive model is only part of the solution: deploying it safely across isolated environments with proper governance, auditability, and network controls is where the real engineering challenge lies.

This lab focuses on the **infrastructure and operations** side of MLOps. The model itself (a Gradient Boosting classifier on synthetic patient data) is intentionally simple — the value is in the end-to-end deployment pattern.

## Architecture

```
┌────────────────────────────────────────────────────────────────────────────┐
│                       GitHub Actions CI/CD (OIDC)                          │
│                                                                            │
│  deploy-infra.yml        train.yml               deploy.yml               │
│  ┌──────────────┐    ┌──────────────────┐   ┌──────────────────────────┐  │
│  │ Lint+What-If │    │ Register → Train  │   │ Deploy Test → Integrate  │  │
│  │  → Deploy    │    │  Dev → Train Test │   │  → Promote → Deploy Prod │  │
│  └──────────────┘    └──────────────────┘   └──────────────────────────┘  │
└────────────────────────────────────────────────────────────────────────────┘
        │                   │             │           │              │
        ▼                   ▼             ▼           ▼              ▼
┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌──────────────────┐
│rg-readmit-   │ │rg-readmit-   │ │rg-readmit-   │ │rg-readmit-prod  │
│  shared      │ │  dev         │ │  test        │ │                  │
│              │ │              │ │              │ │ ML Workspace     │
│ ML Registry  │ │ ML Workspace │ │ ML Workspace │ │ └─ Online        │
│ (model       │ │ ├─ Compute   │ │ ├─ Compute   │ │    Endpoint     │
│  promotion)  │ │ ├─ Pipeline  │ │ ├─ Pipeline  │ │ (inference only)│
│              │ │ └─ Register  │ │ └─ Endpoint  │ │                  │
└──────┬───────┘ └──────────────┘ └──────┬───────┘ └────────▲─────────┘
       │                                 │                   │
       │              az ml model share  │                   │
       │◄────────────────────────────────┘                   │
       │                                                     │
       └─────────────────────────────────────────────────────┘
                    azureml://registries/...
```

### Environment Roles

| Environment | Resource Group | Purpose |
|-------------|---------------|---------|
| **Shared** | `rg-readmit-shared` | ML Registry only — acts as the central artefact store for cross-workspace model promotion |
| **Dev** | `rg-readmit-dev` | Validate pipeline end-to-end on synthetic data. Fast iteration, no approval gates. |
| **Test** | `rg-readmit-test` | Re-train and validate model quality on real (or representative) data. Model registered here is the promotion candidate. |
| **Prod** | `rg-readmit-prod` | Inference only. Deploys the test-validated model from the shared registry via a managed online endpoint. |

## What's Included

| Tier | Component | Description |
|------|-----------|-------------|
| **IaC** | `infra/` | Bicep modules for ML Workspace, shared Registry, compute, RBAC (identity-based, no keys) |
| **Data Science** | `data_science/` | Python 3.13 pipeline: prep, train (GBM + MLflow), evaluate with promotion gate, SDK v2 model registration |
| **Components** | `mlops/azureml/components/` | Reusable component definitions registered in the shared ML Registry — all workspaces consume the same versioned code |
| **CI/CD** | `.github/workflows/` | GitHub Actions with OIDC: infra deploy, training pipeline, and gated promote + deploy |
| **Data** | `scripts/` | Standalone data generation and upload to workspace datastores |
| **Exploration** | `notebooks/` | EDA notebook for exploring generated patient data |
| **Observability** | Built-in | Log Analytics, App Insights, diagnostic settings on every workspace |

## Prerequisites

- Azure subscription with **Contributor** access (subscription-level, for resource group creation)
- **CPU core quota** in your target region (Sweden Central): minimum **44 vCPU** of `Standard DSv2 Family` — breakdown below. [Request a quota increase](https://learn.microsoft.com/azure/quotas/per-vm-quota-requests) if needed.

  | Resource | SKU | Cores | Qty | Subtotal |
  |----------|-----|-------|-----|----------|
  | Compute cluster (dev + test) | Standard_DS3_v2 | 4 | 2 | 8 |
  | Online endpoint (test + prod) | Standard_DS4_v2 | 8 | 2 | 16 |
  | Compute instance (EDA/dev, optional) | Standard_DS3_v2 | 4 | per user | 4 × N |

  > **Compute instances are per-person.** Each data scientist who wants to run notebooks or use VS Code on a compute instance needs their own. For a team of N users, add `4 × N` cores to the total. E.g. a team of 10 needs an additional 40 vCPU on top of the 24 baseline (clusters + endpoints), for a total of **64 vCPU**.

- A [registered Entra ID application](https://learn.microsoft.com/azure/developer/github/connect-from-azure) with federated credentials for GitHub Actions OIDC — one credential per environment (`shared`, `dev`, `test`, `prod`)
  - Each federated credential must have subject filter: `repo:<org>/<repo>:environment:<env-name>`
- [GitHub Environments](https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment) named `shared`, `dev`, `test`, `prod`, and `registry-promotion` created in your repo settings (Settings → Environments).
  - The `registry-promotion` environment **must** have [required reviewers](https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment#required-reviewers) configured — this acts as the governance gate before any component or model is promoted to the shared registry.
  - This environment does **not** need any secrets or federated credentials — it only serves as an approval gate.
  - **⚠️ Note:** Environment protection rules (required reviewers) require **GitHub Team** or **Enterprise** plan for private repositories. Public repos get this on all plans.
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) with the `ml` extension (`az extension add -n ml`) — for local data upload only
- Python 3.13+ (for local data generation only)

### Required GitHub Secrets

| Secret | Description |
|--------|-------------|
| `AZURE_CLIENT_ID` | App registration (service principal) client ID |
| `AZURE_TENANT_ID` | Entra ID tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Target Azure subscription ID |

### Service Principal Roles

The OIDC service principal needs the following roles:

| Role | Scope | Purpose |
|------|-------|---------|
| **Contributor** | Subscription | Create resource groups, deploy Bicep (workspaces, compute, registry), manage ML endpoints |
| **Role Based Access Control Administrator** | Subscription | Deploy RBAC assignments (workspace MI → storage/KV/ACR, compute MI → workspace, registry cross-RG) |
| **Managed Identity Operator** | `rg-readmit-prod` | Attach the User-Assigned Managed Identity to the prod online endpoint |

```bash
SP_ID=$(az ad sp show --id <AZURE_CLIENT_ID> --query id -o tsv)

az role assignment create --assignee-object-id $SP_ID --assignee-principal-type ServicePrincipal \
  --role "Contributor" --scope "/subscriptions/<SUBSCRIPTION_ID>"

az role assignment create --assignee-object-id $SP_ID --assignee-principal-type ServicePrincipal \
  --role "Role Based Access Control Administrator" --scope "/subscriptions/<SUBSCRIPTION_ID>"

az role assignment create --assignee-object-id $SP_ID --assignee-principal-type ServicePrincipal \
  --role "Managed Identity Operator" --scope "/subscriptions/<SUBSCRIPTION_ID>/resourceGroups/rg-readmit-prod"
```

> **Tip:** For production, add a [condition](https://learn.microsoft.com/azure/role-based-access-control/conditions-role-assignments-portal) on the RBAC Administrator role to restrict which roles the SP can assign.

## How to Run

### 1. Deploy Infrastructure

Configure [GitHub OIDC secrets](https://learn.microsoft.com/azure/developer/github/connect-from-azure) (`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`), then trigger the **Deploy Infrastructure** workflow (`multi-env-deploy-infra.yml`) in this order:

1. **shared** — creates resource group + deploys the ML Registry
2. **dev** — creates resource group + deploys dev workspace, compute, RBAC
3. **test** — creates resource group + deploys test workspace, compute, RBAC
4. **prod** — creates resource group + deploys prod workspace, compute, RBAC, and a **User-Assigned Managed Identity** (`readmit-endpoint-identity`) for the online endpoint

The workflow automatically creates the resource group if it doesn't exist, wires the registry ID, and configures identity-based auth. No local CLI commands required.

The prod deployment additionally creates a UAMI with `AzureML Registry User` on the shared registry. This identity is attached to the online endpoint at deployment time so the endpoint can pull models directly from the registry without RBAC propagation delays.

> **⚠️ UAMI Subscription-Level Roles:** Per [Azure docs](https://learn.microsoft.com/en-us/azure/machine-learning/how-to-share-models-pipelines-across-workspaces-with-registries?view=azureml-api-2&tabs=cli), endpoints with a User-Assigned Identity also require **`AcrPull`** and **`Storage Blob Data Reader`** at the **subscription level**. These are needed because the ML Registry stores model artifacts in a system-managed storage account (with a deny assignment that blocks resource-scoped grants). The workflow handles these grants automatically, but if recreating from scratch, run:
>
> ```bash
> UAMI_PRINCIPAL_ID=$(az identity show -n readmit-endpoint-identity -g rg-readmit-prod --query principalId -o tsv)
> az role assignment create --assignee-object-id $UAMI_PRINCIPAL_ID --assignee-principal-type ServicePrincipal --role "Storage Blob Data Reader" --scope "/subscriptions/<SUBSCRIPTION_ID>"
> az role assignment create --assignee-object-id $UAMI_PRINCIPAL_ID --assignee-principal-type ServicePrincipal --role "AcrPull" --scope "/subscriptions/<SUBSCRIPTION_ID>"
> ```

> **⚠️ Important — AML Studio Access:** Because all workspaces enforce identity-based auth (`allowSharedKeyAccess: false`, `enableRbacAuthorization: true`), **users cannot browse files, view data, or run experiments in Azure ML Studio** without explicit data-plane role assignments. The `userPrincipalId` parameter in each `.bicepparam` file exists for this purpose — set it to your Entra object ID to have the IaC automatically grant the required roles. See [User Access for AML Studio](#user-access-for-aml-studio) below.

#### User Access for AML Studio

The `userPrincipalId` parameter (empty by default) controls whether the IaC grants a specific user the data-plane roles required to use Azure ML Studio. When set, the following roles are assigned automatically during infrastructure deployment:

| Role | Scope | Purpose |
|------|-------|---------|
| Contributor | Resource group | Control-plane access to all resources |
| Storage Blob Data Contributor | Storage account | Read/write data assets and pipeline outputs |
| Storage File Data Privileged Contributor | Storage account | Browse the file system in AML Studio |
| Key Vault Secrets User | Key Vault | Studio operations that retrieve workspace secrets |
| AcrPull | Container Registry | View registered environments and images |

**To enable:** Get your Entra object ID and set it in the parameter files before deploying:

```bash
# Get your object ID
az ad signed-in-user show --query id -o tsv
```

Then in `infra/parameters/dev.bicepparam` (and test/prod):

```bicep
param userPrincipalId = '<YOUR_OBJECT_ID>'
```

If left empty (`''`), these role assignments are skipped and you'll get permission errors in AML Studio (e.g. "unable to access file system", "authorization failed on key vault").

#### Optional: Grant Entra Group Access to AML Studio

Because all workspaces use identity-based auth (no shared keys), users need explicit data-plane roles to browse files and run experiments in Azure ML Studio. Create an Entra ID security group and assign the following roles on each workspace's storage account:

```bash
GROUP_ID=$(az ad group show --group "<GROUP_NAME>" --query id -o tsv)

# Repeat for each environment's storage account (readmitdevst, readmittestst, readmitprodst)
STORAGE_ID=$(az storage account show --name readmitdevst --resource-group rg-readmit-dev --query id -o tsv)

az role assignment create --assignee-object-id $GROUP_ID --assignee-principal-type Group \
  --role "Storage Blob Data Contributor" --scope $STORAGE_ID

az role assignment create --assignee-object-id $GROUP_ID --assignee-principal-type Group \
  --role "Storage File Data Privileged Contributor" --scope $STORAGE_ID
```

Also assign on each workspace and Key Vault:

```bash
# Workspace — AzureML Data Scientist
WS_ID=$(az ml workspace show --name readmit-dev-ws --resource-group rg-readmit-dev --query id -o tsv)
az role assignment create --assignee-object-id $GROUP_ID --assignee-principal-type Group \
  --role "AzureML Data Scientist" --scope $WS_ID

# Key Vault — Secrets User (required for Studio)
KV_ID=$(az keyvault show --name readmit-dev-kv --resource-group rg-readmit-dev --query id -o tsv)
az role assignment create --assignee-object-id $GROUP_ID --assignee-principal-type Group \
  --role "Key Vault Secrets User" --scope $KV_ID
```

| Role | Scope | Purpose |
|------|-------|---------|
| AzureML Data Scientist | Workspace | Run experiments, view pipelines, manage endpoints |
| Storage Blob Data Contributor | Storage account | Read/write data assets and pipeline outputs |
| Storage File Data Privileged Contributor | Storage account | Browse file shares in AML Studio |
| Key Vault Secrets User | Key Vault | Workspace operations that retrieve secrets |

### 2. Upload Training Data

Before running the training pipeline, dev and test workspaces need a registered data asset called `readmission-raw-data`. Use the provided script to generate synthetic data and upload it:

```bash
az login
pip install -r requirements.txt

# Upload to dev (default 10 000 samples)
python scripts/generate_and_upload_data.py -g rg-readmit-dev -w <dev-workspace-name>

# Upload to test (larger dataset)
python scripts/generate_and_upload_data.py -g rg-readmit-test -w <test-workspace-name> --num-samples 50000
```

> **Note:** Workspace names follow the pattern `{project}-{env}-<number>-ws` (e.g. `readmit-dev-<number>-ws`). The `--asset-name` defaults to `readmission-raw-data` which the pipeline expects.

In production, replace this with your real data ingestion pipeline (e.g. ADF, Databricks, event-driven).

### 3. Run Workflows

The GitHub Actions workflows handle everything from here:

1. **`multi-env-train.yml`** (manual dispatch via `workflow_dispatch`) — registers components + environment to the shared registry → validates pipeline on dev → promotes components to registry
2. **`multi-env-deploy.yml`** (auto-triggers on train success, or manual dispatch) — retrains on test (full data) → deploys to test endpoint → integration tests → promotes model to shared registry → deploys to prod

> **First run?** You must run `train.yml` at least once before `deploy.yml` — it needs a trained model to deploy.

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| **3 environments + shared registry** | Dev for pipeline validation, test for model quality, prod for inference — clear separation of concerns with a shared registry as the handoff mechanism |
| **Registry-based components** | Pipeline components are registered in the shared registry and consumed by all workspaces — guarantees dev, test, and prod run identical code |
| **Identity-based auth only** | `allowSharedKeyAccess: false` on storage, `enableRbacAuthorization: true` on Key Vault, `auth_mode: aad_token` on endpoints — no keys or secrets anywhere |
| **External data ingestion** | Data is uploaded to workspace datastores as versioned data assets — decouples data production from model training and mirrors real production patterns |
| **Integration tests before promotion** | Model is deployed to a test endpoint and validated (schema + latency) before being promoted to the shared registry |
| **Gated registry promotion** | Both component and model promotion require manual approval via the `registry-promotion` GitHub Environment — mimics real-world governance review before artefacts enter the shared registry |
| **SDK v2 model registration** | `register.py` uses `azure-ai-ml` SDK instead of `mlflow.register_model` to avoid a known `azureml-mlflow` + `mlflow≥2.15` incompatibility with artifact operations |
| **Bicep over Terraform** | Azure-native, first-class AML support, no state file to manage |
| **OIDC federation** | GitHub Actions authenticate via federated identity — no stored secrets |
| **GradientBoostingClassifier** | Simple, interpretable, works well on tabular healthcare data — keeps focus on infra |

## Project Structure

```
├── main.py                              # Local pipeline submission (SDK v2)
├── requirements.txt                     # Local dev dependencies
├── README.md
├── .gitignore / .amlignore
├── scripts/
│   └── generate_and_upload_data.py      # Generate synthetic data & register as data asset
├── notebooks/
│   └── eda.ipynb                        # Exploratory data analysis
├── infra/
│   ├── main.bicep                       # Per-environment orchestrator
│   ├── shared.bicep                     # Shared ML Registry orchestrator
│   ├── parameters/
│   │   ├── shared.bicepparam            # Registry params
│   │   ├── dev.bicepparam
│   │   ├── test.bicepparam
│   │   └── prod.bicepparam
│   └── modules/
│       ├── ml-workspace.bicep           # Workspace + Storage, KV, ACR, AppInsights, Logs
│       ├── ml-registry.bicep            # Shared ML Registry
│       ├── ml-compute.bicep             # Compute cluster (SystemAssigned MI)
│       ├── role-assignments.bicep       # RBAC (workspace MI, compute MI, user)
│       └── registry-role.bicep          # Cross-RG registry RBAC (deployed to shared RG)
├── data_science/
│   ├── config.py                        # Shared column definitions
│   ├── environment/
│   │   └── train-conda.yml              # Python 3.13 conda env
│   └── src/
│       ├── generate_data.py             # Synthetic patient data generator (reused by scripts/)
│       ├── prep.py                      # Clean, one-hot encode, split
│       ├── train.py                     # GBM with MLflow tracking
│       ├── evaluate.py                  # Test metrics + multi-threshold promotion gate (AUC, F1, Precision, Recall)
│       └── register.py                  # Conditional registration (SDK v2)
├── mlops/
│   └── azureml/
│       ├── components/
│       │   ├── prep.yml                 # Prep component (registered in shared registry)
│       │   ├── train.yml                # Train component
│       │   ├── evaluate.yml             # Evaluate component
│       │   └── register.yml             # Register component
│       ├── train/
│       │   ├── pipeline.yml             # 4-step pipeline (references registry components)
│       │   ├── pipeline-dev.yml         # Dev pipeline (workspace-local component references)
│       │   └── train-env.yml            # Environment spec (registered in shared registry)
│       └── deploy/
│           └── online/
│               ├── online-endpoint.yml  # AAD-token auth endpoint
│               └── online-deployment.yml# Blue deployment from registry
├── data/
│   └── sample-request.json              # Example inference payload
└── .github/workflows/
    ├── multi-env-deploy-infra.yml       # Bicep lint → what-if → deploy
    ├── multi-env-train.yml              # Register components → train dev → train test
    └── multi-env-deploy.yml             # Deploy test → integration tests → promote → deploy prod
```

## Tech Stack

| Technology | Version |
|------------|---------|
| Python | 3.13 |
| scikit-learn | ≥1.5 |
| MLflow | ≥2.15 |
| Azure ML SDK | v2 (`azure-ai-ml` ≥1.20) |
| Bicep | Latest |
| GitHub Actions | v4 actions, OIDC auth |
| Azure Region | Sweden Central |
