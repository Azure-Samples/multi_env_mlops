// ---------------------------------------------------------------------------
// RBAC role assignments for the multi-environment MLOps lab
// ---------------------------------------------------------------------------

@description('Principal ID of the ML workspace managed identity.')
param workspacePrincipalId string

@description('Resource ID of the storage account.')
param storageAccountId string

@description('Resource ID of the key vault.')
param keyVaultId string

@description('Resource ID of the container registry.')
param acrId string

@description('Principal ID of the compute cluster managed identity.')
param computePrincipalId string = ''

@description('Principal ID of a user or SPN to grant workspace data-plane access. Get your object ID with: az ad signed-in-user show --query id -o tsv. Leave empty to skip role assignments for this user.')
param userPrincipalId string = ''

@description('Resource ID of the ML workspace (for compute MI scoped roles).')
param workspaceId string

@description('Set to true to skip all role assignments (use when they already exist to avoid RoleAssignmentExists errors).')
param skipRoleAssignments bool = false


// ---------------------------------------------------------------------------
// skipWorkspaceBaselineRoleAssignments: Set to true to skip only the baseline RBAC assignments
// (Storage, Key Vault, ACR) for the workspace managed identity. This is useful when Azure ML
// workspace provisioning already creates these assignments automatically, which can cause
// RoleAssignmentExists errors if Bicep tries to create them again. Use this for dev/test environments
// where you observe duplicate RBAC creation or RoleAssignmentExists errors.
// ---------------------------------------------------------------------------
@description('Set to true to skip only workspace managed identity baseline roles (Storage/Key Vault/ACR). Useful when AML provisioning already creates equivalent assignments.')
param skipWorkspaceBaselineRoleAssignments bool = false

@description('Set to true to skip user/SPN access role assignments (Contributor + Storage/Key Vault/ACR user roles).')
param skipUserRoleAssignments bool = false

// Well-known built-in role definition IDs
var storageBlobDataContributor = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var storageFileDataPrivilegedContributor = '69566ab7-960f-475b-8e7c-b3118f30c6bd'
var keyVaultAdministrator = '00482a5a-887f-4fb3-b363-3b7fe8e74483'
var keyVaultSecretsUser = '4633458b-17de-408a-b874-0445c86b69e6'
var acrPush = '8311e382-0749-4cb8-b61a-304f252e45ec'
var acrPull = '7f951dda-4ed3-4680-a7ca-43fe172d538d'
var azureMLDataScientist = 'f6c7c914-8db3-469d-8ca1-694a8f32e121'
var contributor = 'b24988ac-6180-42a0-ab88-20f7382dd24c'

// Extract resource names from IDs
var storageName = last(split(storageAccountId, '/'))
var kvName = last(split(keyVaultId, '/'))
var acrName = last(split(acrId, '/'))
var workspaceName = last(split(workspaceId, '/'))

// ---------- Workspace MI → Storage ----------

resource storageRef 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageName
}

resource storageRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!skipRoleAssignments && !skipWorkspaceBaselineRoleAssignments) {
  name: guid(storageAccountId, workspacePrincipalId, storageBlobDataContributor)
  scope: storageRef
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributor)
    principalId: workspacePrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ---------- Workspace MI → Key Vault ----------

resource kvRef 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: kvName
}

resource kvRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!skipRoleAssignments && !skipWorkspaceBaselineRoleAssignments) {
  name: guid(keyVaultId, workspacePrincipalId, keyVaultAdministrator)
  scope: kvRef
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultAdministrator)
    principalId: workspacePrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ---------- Workspace MI → ACR ----------

resource acrRef 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' existing = {
  name: acrName
}

resource acrRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!skipRoleAssignments && !skipWorkspaceBaselineRoleAssignments) {
  name: guid(acrId, workspacePrincipalId, acrPush)
  scope: acrRef
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPush)
    principalId: workspacePrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ---------- Compute MI → Storage (data read/write for pipeline jobs) ----------

resource computeStorageRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!skipRoleAssignments && !empty(computePrincipalId)) {
  name: guid(storageAccountId, computePrincipalId, storageBlobDataContributor)
  scope: storageRef
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributor)
    principalId: computePrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ---------- Compute MI → Workspace (AzureML Data Scientist for model registration) ----------

resource workspaceRef 'Microsoft.MachineLearningServices/workspaces@2024-04-01' existing = {
  name: workspaceName
}

resource computeDataScientistRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!skipRoleAssignments && !empty(computePrincipalId)) {
  name: guid(workspaceId, computePrincipalId, azureMLDataScientist)
  scope: workspaceRef
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', azureMLDataScientist)
    principalId: computePrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ---------- User / SPN → Resource Group (Contributor) ----------

resource userRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!skipRoleAssignments && !skipUserRoleAssignments && !empty(userPrincipalId)) {
  name: guid(resourceGroup().id, userPrincipalId, contributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', contributor)
    principalId: userPrincipalId
    principalType: 'User'
  }
}

// ---------- User / SPN → Storage (Blob Data Contributor for CLI data ops) ----------

resource userStorageRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!skipRoleAssignments && !skipUserRoleAssignments && !empty(userPrincipalId)) {
  name: guid(storageAccountId, userPrincipalId, storageBlobDataContributor)
  scope: storageRef
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributor)
    principalId: userPrincipalId
    principalType: 'User'
  }
}

// ---------- User → Storage (File Data Privileged Contributor for AML Studio file browser) ----------

resource userStorageFileRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!skipRoleAssignments && !skipUserRoleAssignments && !empty(userPrincipalId)) {
  name: guid(storageAccountId, userPrincipalId, storageFileDataPrivilegedContributor)
  scope: storageRef
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageFileDataPrivilegedContributor)
    principalId: userPrincipalId
    principalType: 'User'
  }
}

// ---------- User → Key Vault (Secrets User for AML Studio) ----------

resource userKvRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!skipRoleAssignments && !skipUserRoleAssignments && !empty(userPrincipalId)) {
  name: guid(keyVaultId, userPrincipalId, keyVaultSecretsUser)
  scope: kvRef
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUser)
    principalId: userPrincipalId
    principalType: 'User'
  }
}

// ---------- User → ACR (Pull for viewing environments) ----------

resource userAcrRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!skipRoleAssignments && !skipUserRoleAssignments && !empty(userPrincipalId)) {
  name: guid(acrId, userPrincipalId, acrPull)
  scope: acrRef
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPull)
    principalId: userPrincipalId
    principalType: 'User'
  }
}


