// ---------------------------------------------------------------------------
// Subscription-scoped role assignments for the endpoint UAMI
//
// These roles are required for UAMI-based online endpoints that pull models
// from the shared ML Registry. The registry's backing storage/ACR live in a
// system-managed RG with deny assignments, so subscription-level grants are
// the only way to provide access.
//
// Deploy with:
//   az deployment sub create --location <region> --template-file endpoint-sub-roles.bicep ...
// ---------------------------------------------------------------------------

targetScope = 'subscription'

@description('Principal ID of the endpoint User-Assigned Managed Identity.')
param endpointPrincipalId string

// Well-known built-in role definition IDs
var storageBlobDataReader = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
var acrPull = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

resource storageBlobDataReaderRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, endpointPrincipalId, storageBlobDataReader)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataReader)
    principalId: endpointPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource acrPullRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, endpointPrincipalId, acrPull)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPull)
    principalId: endpointPrincipalId
    principalType: 'ServicePrincipal'
  }
}
