// ---------------------------------------------------------------------------
// Azure ML Workspace with all dependent resources (identity-based auth only)
// ---------------------------------------------------------------------------

@description('Base name for the workspace and dependent resources.')
param baseName string

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Tags applied to every resource.')
param tags object = {}

@description('SKU for Container Registry (Basic, Standard, or Premium).')
@allowed(['Basic', 'Standard', 'Premium'])
param acrSku string = 'Basic'

@description('Log Analytics retention in days (30-730).')
@minValue(30)
@maxValue(730)
param logRetentionDays int = 30

@description('Optional suffix used to make Key Vault names dynamic per deployment run.')
param keyVaultNameSuffix string = ''

@description('Optional suffix used to make workspace name dynamic per deployment run.')
param workspaceNameSuffix string = ''

// ---------- Derived variables ----------
// Resource names must be globally unique and follow Azure naming constraints
var uniqueSuffix = toLower(substring(uniqueString(resourceGroup().id), 0, 6))
// Storage accounts: 3-24 chars, lowercase letters and numbers only
var storageNameBase = replace('${baseName}st', '-', '')
var storageName = take('${storageNameBase}${uniqueSuffix}', 24)
// Container Registry: 5-50 chars, alphanumeric only
var acrNameBase = replace('${baseName}cr', '-', '')
var acrName = take('${acrNameBase}${uniqueSuffix}', 50)
// Key Vault: 3-24 chars, alphanumeric and hyphens allowed
// Build name as <trimmed-base>-<suffix> so dynamic suffix is always retained within 24 chars.
var kvSuffix = empty(keyVaultNameSuffix) ? uniqueSuffix : take(toLower(keyVaultNameSuffix), 8)
var kvBase = take('${baseName}-kv', 23 - length(kvSuffix))
var keyVaultName = '${kvBase}-${kvSuffix}'
// Workspace: max 33 chars. Build as <trimmed-base>-<suffix>-ws.
var wsSuffix = empty(workspaceNameSuffix) ? uniqueSuffix : take(toLower(workspaceNameSuffix), 8)
var wsBase = take(baseName, 29 - length(wsSuffix))
var workspaceName = '${wsBase}-${wsSuffix}-ws'

// ---------- Log Analytics ----------

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${baseName}-logs'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: logRetentionDays
  }
}

// ---------- Application Insights ----------

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${baseName}-ai'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

// ---------- Storage Account (identity-based, no key access) ----------
// NOTE: Uses a 5-char unique suffix to stay within the 24-character limit
// required by Azure Storage naming standards (3-24 chars, lowercase + numbers only).
// Prevents "StorageAccountAlreadyTaken" errors while meeting naming constraints.

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowSharedKeyAccess: false
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
  }
}

// ---------- Key Vault (RBAC mode, no access policies) ----------
// NOTE: Added unique suffix to prevent global name collisions
// Key Vault names must be globally unique across Azure

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
  }
}

// ---------- Container Registry ----------
// NOTE: Added unique suffix to prevent global name collisions
// Container Registry names must be globally unique across Azure

resource acr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  name: acrName
  location: location
  tags: tags
  sku: {
    name: acrSku
  }
  properties: {
    adminUserEnabled: false
  }
}

// ---------- Azure ML Workspace ----------

resource workspace 'Microsoft.MachineLearningServices/workspaces@2024-10-01' = {
  // Include dynamic suffix support to avoid collisions with soft-deleted workspace names.
  name: workspaceName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    friendlyName: '${baseName} Workspace'
    storageAccount: storage.id
    keyVault: keyVault.id
    applicationInsights: appInsights.id
    containerRegistry: acr.id
  }
}

// ---------- Diagnostic Settings ----------

resource wsDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${baseName}-ws-diag'
  scope: workspace
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// ---------- Outputs ----------

output workspaceId string = workspace.id
output workspaceName string = workspace.name
output workspacePrincipalId string = workspace.identity.principalId
output storageAccountId string = storage.id
output keyVaultId string = keyVault.id
output acrId string = acr.id
output logAnalyticsId string = logAnalytics.id
output appInsightsId string = appInsights.id
