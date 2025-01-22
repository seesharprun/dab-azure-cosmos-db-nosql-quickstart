metadata description = 'Provisions resources for a web application that uses Azure SDK for Go to connect to Azure Cosmos DB for NoSQL.'

targetScope = 'resourceGroup'

@minLength(1)
@maxLength(64)
@description('Name of the environment that can be used as part of naming resource convention.')
param environmentName string

@minLength(1)
@description('Primary location for all resources.')
param location string

@description('Id of the principal to assign database and application roles.')
param deploymentUserPrincipalId string = ''

// serviceName is used as value for the tag (azd-service-name) azd uses to identify deployment host
param apiServiceName string = 'api'
param webServiceName string = 'web'

var resourceToken = toLower(uniqueString(resourceGroup().id, environmentName, location))
var tags = {
  'azd-env-name': environmentName
  repo: 'https://github.com/azure-samples/dab-azure-cosmos-db-nosql-quickstart'
}

module managedIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.4.0' = {
  name: 'user-assigned-identity'
  params: {
    name: 'managed-identity-${resourceToken}'
    location: location
    tags: tags
  }
}

module cosmosDbAccount 'br/public:avm/res/document-db/database-account:0.8.1' = {
  name: 'cosmos-db-account'
  params: {
    name: 'cosmos-db-nosql-${resourceToken}'
    location: location
    locations: [
      {
        failoverPriority: 0
        locationName: location
        isZoneRedundant: false
      }
    ]
    tags: tags
    disableKeyBasedMetadataWriteAccess: true
    disableLocalAuth: true
    networkRestrictions: {
      publicNetworkAccess: 'Enabled'
      ipRules: []
      virtualNetworkRules: []
    }
    capabilitiesToAdd: [
      'EnableServerless'
    ]
    sqlRoleDefinitions: [
      {
        name: 'nosql-data-plane-contributor'
        dataAction: [
          'Microsoft.DocumentDB/databaseAccounts/readMetadata'
          'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/*'
          'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/*'
        ]
      }
    ]
    sqlRoleAssignmentsPrincipalIds: union(
      [
        managedIdentity.outputs.principalId
      ],
      !empty(deploymentUserPrincipalId) ? [deploymentUserPrincipalId] : []
    )
    sqlDatabases: [
      {
        name: 'cosmicworks'
        containers: [
          {
            name: 'products'
            paths: [
              '/category/name'
            ]
          }
        ]
      }
    ]
  }
}

module deploymentScript 'br/public:avm/res/resources/deployment-script:0.5.1' = {
  name: 'deployment-script-ps'
  params: {
    name: 'deployment-script-ps-demo'
    location: resourceGroup().location
    kind: 'AzurePowerShell'
    azPowerShellVersion: '12.0'
    runOnce: true
    managedIdentities: {
      userAssignedResourceIds: [
        managedIdentity.outputs.resourceId
      ]
    }
    environmentVariables: [
      {
        name: 'AZURE_COSMOS_DB_ENDPOINT'
        value: cosmosDbAccount.outputs.endpoint
      }
    ]
    scriptContent: '''
      apt-get update
      apt-get install -y dotnet-sdk-8.0 
      dotnet tool install cosmicworks --tool-path ~/dotnet-tool
      ~/dotnet-tool/cosmicworks --endpoint "${Env:AZURE_COSMOS_DB_ENDPOINT}" --number-of-products 100 --number-of-employees 0 --role-based-access-control --hide-credentials --disable-hierarchical-partition-keys --disable-formatting
    '''
  }
}

module containerRegistry 'br/public:avm/res/container-registry/registry:0.7.0' = {
  name: 'container-registry'
  params: {
    name: 'containerreg${resourceToken}'
    location: location
    tags: tags
    acrAdminUserEnabled: false
    anonymousPullEnabled: true
    publicNetworkAccess: 'Enabled'
    acrSku: 'Standard'
  }
}

var containerRegistryRole = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '8311e382-0749-4cb8-b61a-304f252e45ec'
) // AcrPush built-in role

module registryUserAssignment 'br/public:avm/ptn/authorization/resource-role-assignment:0.1.1' = if (!empty(deploymentUserPrincipalId)) {
  name: 'container-registry-role-assignment-push-user'
  params: {
    principalId: deploymentUserPrincipalId
    resourceId: containerRegistry.outputs.resourceId
    roleDefinitionId: containerRegistryRole
  }
}

module logAnalyticsWorkspace 'br/public:avm/res/operational-insights/workspace:0.7.0' = {
  name: 'log-analytics-workspace'
  params: {
    name: 'log-analytics-${resourceToken}'
    location: location
    tags: tags
  }
}

module containerAppsEnvironment 'br/public:avm/res/app/managed-environment:0.8.0' = {
  name: 'container-apps-env'
  params: {
    name: 'container-env-${resourceToken}'
    location: location
    tags: tags
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspace.outputs.resourceId
    zoneRedundant: false
  }
}

module containerAppsApiApp 'br/public:avm/res/app/container-app:0.12.0' = {
  name: 'container-apps-app-api'
  params: {
    name: 'container-app-api-${resourceToken}'
    environmentResourceId: containerAppsEnvironment.outputs.resourceId
    location: location
    tags: union(tags, { 'azd-service-name': apiServiceName })
    ingressTargetPort: 5000
    ingressExternal: true
    ingressTransport: 'auto'
    stickySessionsAffinity: 'sticky'
    scaleMaxReplicas: 1
    scaleMinReplicas: 1
    corsPolicy: {
      allowCredentials: true
      allowedOrigins: [
        '*'
      ]
    }
    managedIdentities: {
      systemAssigned: false
      userAssignedResourceIds: [
        managedIdentity.outputs.resourceId
      ]
    }
    secrets: {
      secureList: [
        {
          name: 'azure-cosmos-db-nosql-connection-string'
          value: 'AccountEndpoint=${cosmosDbAccount.outputs.endpoint};'
        }
        {
          name: 'user-assigned-managed-identity-client-id'
          value: managedIdentity.outputs.clientId
        }
      ]
    }
    containers: [
      {
        image: 'mcr.microsoft.com/azure-databases/data-api-builder:latest'
        name: 'web-front-end'
        resources: {
          cpu: '0.25'
          memory: '.5Gi'
        }
        env: [
          {
            name: 'AZURE_COSMOS_DB_NOSQL_CONNECTION_STRING'
            secretRef: 'azure-cosmos-db-nosql-connection-string'
          }
          {
            name: 'AZURE_CLIENT_ID'
            secretRef: 'user-assigned-managed-identity-client-id'
          }
        ]
      }
    ]
  }
}

module containerAppsWebApp 'br/public:avm/res/app/container-app:0.12.0' = {
  name: 'container-apps-app-web'
  params: {
    name: 'container-app-web-${resourceToken}'
    environmentResourceId: containerAppsEnvironment.outputs.resourceId
    location: location
    tags: union(tags, { 'azd-service-name': webServiceName })
    ingressTargetPort: 8080
    ingressExternal: true
    ingressTransport: 'auto'
    stickySessionsAffinity: 'sticky'
    scaleMaxReplicas: 1
    scaleMinReplicas: 1
    corsPolicy: {
      allowCredentials: true
      allowedOrigins: [
        '*'
      ]
    }
    managedIdentities: {
      systemAssigned: false
      userAssignedResourceIds: [
        managedIdentity.outputs.resourceId
      ]
    }
    secrets: {
      secureList: [
        {
          name: 'data-api-builder-endpoint'
          value: 'http://${containerAppsApiApp.outputs.fqdn}/graphql'
        }
      ]
    }
    containers: [
      {
        image: 'mcr.microsoft.com/azure-databases/data-api-builder:latest'
        name: 'web-front-end'
        resources: {
          cpu: '0.25'
          memory: '.5Gi'
        }
        env: [
          {
            name: 'CONFIGURATION__DATAAPIBUILDER__BASEAPIURL'
            secretRef: 'data-api-builder-endpoint'
          }
        ]
      }
    ]
  }
}

// Azure Container Apps outputs
output AZURE_CONTAINER_APPS_API_ENDPOINT string = containerAppsApiApp.outputs.fqdn
output AZURE_CONTAINER_APPS_WEB_ENDPOINT string = containerAppsWebApp.outputs.fqdn

// Azure Container Registry outputs
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = containerRegistry.outputs.loginServer
