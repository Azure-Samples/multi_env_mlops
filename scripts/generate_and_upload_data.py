"""Generate synthetic patient data and register it as an Azure ML data asset.

This script simulates data arriving in storage — in production you'd replace
this with your actual data ingestion pipeline (e.g. ADF, Databricks, etc.).

Usage:
    python scripts/generate_and_upload_data.py --workspace readmit-dev-ws --resource-group rg-readmit-dev
    python scripts/generate_and_upload_data.py --workspace readmit-test-ws --resource-group rg-readmit-test
"""

import argparse
import tempfile
from pathlib import Path

from azure.ai.ml import MLClient
from azure.ai.ml.entities import Data
from azure.ai.ml.constants import AssetTypes
from azure.identity import DefaultAzureCredential

# Reuse the existing generation logic
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "data_science"))
from src.generate_data import generate_patients


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate synthetic data and register as an Azure ML data asset."
    )
    parser.add_argument("--resource-group", "-g", type=str, required=True)
    parser.add_argument("--workspace", "-w", type=str, required=True)
    parser.add_argument("--subscription-id", "-s", type=str, default=None,
                        help="Azure subscription ID. If omitted, uses 'az account show'.")
    parser.add_argument("--num-samples", type=int, default=20_000)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--asset-name", type=str, default="readmission-raw-data")
    parser.add_argument(
        "--local-only", action="store_true",
        help="Only generate locally to data/patients.csv without uploading."
    )
    args = parser.parse_args()

    # Generate data
    df = generate_patients(args.num_samples, seed=args.seed)
    print(f"Generated {len(df)} records (readmission rate: {df['readmitted_30d'].mean():.1%})")

    if args.local_only:
        output_path = Path("data/patients.csv")
        output_path.parent.mkdir(parents=True, exist_ok=True)
        df.to_csv(output_path, index=False)
        print(f"Saved locally: {output_path}")
        return

    # Upload and register as a versioned data asset
    credential = DefaultAzureCredential()

    subscription_id = args.subscription_id
    if not subscription_id:
        import subprocess as _sp
        import shutil
        az_cmd = shutil.which("az") or shutil.which("az.cmd") or "az.cmd"
        result = _sp.run(
            [az_cmd, "account", "show", "--query", "id", "-o", "tsv"],
            capture_output=True, text=True
        )
        subscription_id = result.stdout.strip()
        if not subscription_id:
            raise SystemExit(
                "Could not determine subscription ID. Pass --subscription-id or ensure 'az login' is active."
            )

    ml_client = MLClient(
        credential=credential,
        subscription_id=subscription_id,
        resource_group_name=args.resource_group,
        workspace_name=args.workspace,
    )

    # Get the default datastore details (account + container)
    datastore = ml_client.datastores.get_default()
    account_name = datastore.account_name
    container_name = datastore.container_name
    blob_name = f"data/{args.asset_name}/patients.csv"

    with tempfile.TemporaryDirectory() as tmpdir:
        csv_path = Path(tmpdir) / "patients.csv"
        df.to_csv(csv_path, index=False)

        # Upload directly via az storage blob upload using identity (Entra auth)
        import subprocess as _sp
        import shutil
        az_cmd = shutil.which("az") or shutil.which("az.cmd") or "az.cmd"
        upload_result = _sp.run(
            [
                az_cmd, "storage", "blob", "upload",
                "--account-name", account_name,
                "--container-name", container_name,
                "--name", blob_name,
                "--file", str(csv_path),
                "--auth-mode", "login",
                "--overwrite", "true",
            ],
            capture_output=True, text=True
        )
        if upload_result.returncode != 0:
            raise SystemExit(f"Blob upload failed:\n{upload_result.stderr}")
        print(f"Uploaded to: {account_name}/{container_name}/{blob_name}")

        # Register as a data asset pointing to the uploaded blob
        blob_uri = f"azureml://datastores/workspaceblobstore/paths/{blob_name}"
        data_asset = Data(
            name=args.asset_name,
            path=blob_uri,
            type=AssetTypes.URI_FILE,
            description=f"Synthetic patient data ({args.num_samples} records, seed={args.seed})",
        )
        registered = ml_client.data.create_or_update(data_asset)
        print(f"Registered: {registered.name} v{registered.version}")
        print(f"Path: {registered.path}")


if __name__ == "__main__":
    main()
