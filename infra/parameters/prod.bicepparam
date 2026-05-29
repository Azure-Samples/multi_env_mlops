using '../main.bicep'

param environment = 'prod'
param projectName = 'readmit'
param location = 'swedencentral'
param mlRegistryId = ''
param computeVmSize = 'Standard_DS3_v2'
param computeMaxNodes = 1
param deployEndpointIdentity = true

// Set to your Entra object ID (az ad signed-in-user show --query id -o tsv) to grant
// AML Studio data-plane access (Storage Blob/File, Key Vault, ACR). Leave empty to skip.
param userPrincipalId = ''
param acrSku = 'Standard'
param logRetentionDays = 90

// Set to true when role assignments already exist in Azure to avoid RoleAssignmentExists errors.
// Set to false only when deploying to a brand new environment for the first time.

// --- RBAC idempotency patch (2026-05-20) ---
// Set to true to skip workspace managed identity baseline role assignments (Key Vault Admin, Storage Blob Contributor, etc.)
// Use this if you see RoleAssignmentExists errors for workspace MI roles and they already exist in the subscription.
param skipWorkspaceBaselineRoleAssignments = true

// Set to true to skip user role assignments (for userPrincipalId) if they already exist.
// Use this if you see RoleAssignmentExists errors for user RBAC assignments.
param skipUserRoleAssignments = false

// --- End RBAC idempotency patch ---
