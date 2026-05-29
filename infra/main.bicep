// ---------------------------------------------------------------------------
// Multi-Environment MLOps — Main Bicep Orchestrator
//
// Deploys:
//   - Azure ML Workspace + dependencies (Storage, Key Vault, ACR, App Insights, Log Analytics)
//   - Compute cluster
//   - RBAC role assignments (identity-based, no keys)
//
// The shared ML Registry is deployed separately via shared.bicep into its own
// resource group. Pass its resource ID here so workspace RBAC can reference it.
// ---------------------------------------------------------------------------

targetScope = 'resourceGroup'

@description('Environment name used as a prefix (e.g. dev, test, prod).')
param environment string

@description('Project short name.')
param projectName string = 'readmit'

@description('Azure region.')
param location string = resourceGroup().location

@description('Resource ID of the shared ML Registry (deployed via shared.bicep). Leave empty to skip registry RBAC.')
param mlRegistryId string = ''

@description('VM size for compute cluster.')
param computeVmSize string = 'Standard_DS3_v2'

@description('Max nodes for compute cluster.')
param computeMaxNodes int = 4

@description('Principal ID of the user to grant data-plane access to AML Studio (Storage Blob/File, Key Vault, ACR). Leave empty to skip. See README: User Access for AML Studio.')
param userPrincipalId string = ''

@description('Set to true to skip role assignments when they already exist (avoids RoleAssignmentExists errors on re-deployments).')
param skipRoleAssignments bool = false


// ---------------------------------------------------------------------------
// skipWorkspaceBaselineRoleAssignments: Set to true to skip only the baseline RBAC assignments
// (Storage, Key Vault, ACR) for the workspace managed identity. This is useful when Azure ML
// workspace provisioning already creates these assignments automatically, which can cause
// RoleAssignmentExists errors if Bicep tries to create them again. Use this for dev/test environments
// where you observe duplicate RBAC creation or RoleAssignmentExists errors.
// ---------------------------------------------------------------------------
@description('Set to true to skip only workspace managed identity baseline roles (Storage/Key Vault/ACR).')
param skipWorkspaceBaselineRoleAssignments bool = false

@description('Set to true to skip user/SPN access role assignments (Contributor + Storage/Key Vault/ACR user roles).')
param skipUserRoleAssignments bool = false

@description('SKU for Container Registry (Basic, Standard, or Premium).')
@allowed(['Basic', 'Standard', 'Premium'])
param acrSku string = 'Basic'

@description('Log Analytics retention in days.')
param logRetentionDays int = 30

@description('Optional suffix used to make Key Vault names dynamic per deployment run.')
param keyVaultNameSuffix string = ''

@description('Optional suffix used to make workspace name dynamic per deployment run.')
param workspaceNameSuffix string = ''

@description('Deploy a User-Assigned Managed Identity for online endpoints (needed for prod registry access).')
param deployEndpointIdentity bool = false

// ---------- Derived names ----------

var baseName = '${projectName}-${environment}'
// Must match the workspace naming logic in modules/ml-workspace.bicep.
var uniqueSuffix = toLower(substring(uniqueString(resourceGroup().id), 0, 6))
var wsSuffix = empty(workspaceNameSuffix) ? uniqueSuffix : take(toLower(workspaceNameSuffix), 8)
var wsBase = take(baseName, 29 - length(wsSuffix))
var workspaceName = '${wsBase}-${wsSuffix}-ws'

var tags = {
  project: projectName
  environment: environment
  managedBy: 'bicep'
}

// ---------- ML Workspace + dependencies ----------

module workspace 'modules/ml-workspace.bicep' = {
  name: 'workspace-${environment}'
  params: {
    baseName: baseName
    location: location
    tags: tags
    acrSku: acrSku
    logRetentionDays: logRetentionDays
    keyVaultNameSuffix: keyVaultNameSuffix
    workspaceNameSuffix: workspaceNameSuffix
  }
}

// ---------- Compute ----------

module compute 'modules/ml-compute.bicep' = {
  name: 'compute-${environment}'
  params: {
    workspaceId: workspace.outputs.workspaceId
    clusterName: 'cpu-cluster'
    vmSize: computeVmSize
    minNodeCount: 0
    maxNodeCount: computeMaxNodes
    location: location
    tags: tags
  }
}

// ---------- RBAC ----------

module roles 'modules/role-assignments.bicep' = {
  name: 'roles-${environment}'
  params: {
    workspacePrincipalId: workspace.outputs.workspacePrincipalId
    computePrincipalId: compute.outputs.computePrincipalId
    storageAccountId: workspace.outputs.storageAccountId
    keyVaultId: workspace.outputs.keyVaultId
    acrId: workspace.outputs.acrId
    userPrincipalId: userPrincipalId
    workspaceId: workspace.outputs.workspaceId
    skipRoleAssignments: skipRoleAssignments
    skipWorkspaceBaselineRoleAssignments: skipWorkspaceBaselineRoleAssignments
    skipUserRoleAssignments: skipUserRoleAssignments
  }
}

// ---------- Registry RBAC (cross-resource-group) ----------

// Extract the resource group name from the registry resource ID
var registryRgName = !empty(mlRegistryId) ? split(mlRegistryId, '/')[4] : resourceGroup().name

module registryRbac 'modules/registry-role.bicep' = if (!empty(mlRegistryId)) {
  name: 'registry-rbac-${environment}'
  scope: resourceGroup(registryRgName)
  params: {
    mlRegistryId: mlRegistryId
    principalId: workspace.outputs.workspacePrincipalId
  }
}

// ---------- Endpoint Identity (prod only) ----------

resource endpointIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (deployEndpointIdentity) {
  name: '${projectName}-endpoint-identity'
  location: location
  tags: tags
}

// Existing reference to the workspace for endpoint identity role scoping
resource workspaceRef 'Microsoft.MachineLearningServices/workspaces@2024-10-01' existing = {
  name: workspaceName
}

// Grant AzureML Registry User to the endpoint identity on the shared ML registry
module endpointRegistryRbac 'modules/registry-role.bicep' = if (deployEndpointIdentity && !empty(mlRegistryId)) {
  name: 'endpoint-registry-rbac-${environment}'
  scope: resourceGroup(registryRgName)
  params: {
    mlRegistryId: mlRegistryId
    principalId: endpointIdentity!.properties.principalId
  }
}

// Grant AzureML Data Scientist to the endpoint identity on the workspace
var azureMLDataScientistRoleId = 'f6c7c914-8db3-469d-8ca1-694a8f32e121'

resource endpointWorkspaceRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployEndpointIdentity) {
  // Explicitly wait for workspace creation before role assignment.
  // This avoids intermittent ResourceNotFound on fresh workspace names.
  dependsOn: [
    workspace
  ]
  name: guid(workspaceRef.id, endpointIdentity!.id, azureMLDataScientistRoleId)
  scope: workspaceRef
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', azureMLDataScientistRoleId)
    principalId: endpointIdentity!.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Subscription-level roles (Storage Blob Data Reader + AcrPull) are deployed
// separately via endpoint-sub-roles.bicep (subscription-scoped deployment).

// ---------- Outputs ----------

output workspaceName string = workspace.outputs.workspaceName
output workspaceId string = workspace.outputs.workspaceId
output computeName string = compute.outputs.computeName
output endpointIdentityId string = deployEndpointIdentity ? endpointIdentity!.id : ''
