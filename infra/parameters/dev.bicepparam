using '../main.bicep'

param environment = 'dev'
param projectName = 'readmit'
param location = 'swedencentral'
param mlRegistryId = ''
param computeVmSize = 'Standard_DS3_v2'
param computeMaxNodes = 2

// Set to your Entra object ID (az ad signed-in-user show --query id -o tsv) to grant
// AML Studio data-plane access (Storage Blob/File, Key Vault, ACR). Leave empty to skip.
param userPrincipalId = ''

// Set to true when role assignments already exist in Azure to avoid RoleAssignmentExists errors.
// Set to false for fresh environment or when first setting userPrincipalId.
param skipRoleAssignments = false


// Dev-only: skipWorkspaceBaselineRoleAssignments is set to true to avoid duplicate RBAC creation for the workspace managed identity.
// Azure ML workspace provisioning can automatically create Storage/KeyVault/ACR assignments, so this prevents RoleAssignmentExists errors
// during dev deployments. Set to false in prod unless you observe the same issue.
param skipWorkspaceBaselineRoleAssignments = true
