using '../main.bicep'

param environment = 'test'
param projectName = 'readmit'
param location = 'swedencentral'
param mlRegistryId = ''
param computeVmSize = 'Standard_DS3_v2'
param computeMaxNodes = 2

// Enable AML Studio user access by setting your Entra object ID here.
// Set to your Entra object ID (az ad signed-in-user show --query id -o tsv) to grant
// AML Studio data-plane access (Storage Blob/File, Key Vault, ACR). Leave empty to skip.
param userPrincipalId = ''

// Set to true when role assignments already exist in Azure to avoid RoleAssignmentExists errors.
// Set to false only when deploying to a brand new environment for the first time.
param skipRoleAssignments = false

// Test-only: skipWorkspaceBaselineRoleAssignments is set to true to avoid duplicate RBAC creation for the workspace managed identity.
// Azure ML workspace provisioning can automatically create Storage/KeyVault/ACR assignments, so this prevents RoleAssignmentExists errors
// during test deployments. Set to false in prod unless you observe the same issue.
param skipWorkspaceBaselineRoleAssignments = true

// Test-only: skip user/SPN access role assignments to avoid recurring RoleAssignmentExists conflicts
// for Contributor/Storage/KeyVault/ACR user roles in CI re-deployments. Keep enabled for automated
// test environment deployments; grant user access manually only when needed.
param skipUserRoleAssignments = false
