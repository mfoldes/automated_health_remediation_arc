@{
    Commercial = @{
        AzEnvironment                 = 'AzureCloud'
        AzcmagentCloud                = 'AzureCloud'
        ArmEndpoint                   = 'https://management.azure.com'
        EntraAuthority                = 'https://login.microsoftonline.com'
        StorageSuffix                 = 'blob.core.windows.net'
        ArmTokenResource              = 'https://management.azure.com/'
        MonitorTokenScope             = 'https://monitor.azure.com/.default'
        ExpectedAgentCloudValues      = @('AzureCloud')
        SupportsArcGateway            = $true
        SupportsAutomaticAgentUpgrade = $true
    }

    AzureGovernmentDoD = @{
        AzEnvironment                 = 'AzureUSGovernment'
        AzcmagentCloud                = 'AzureUSGovernment'
        ArmEndpoint                   = 'https://management.usgovcloudapi.net'
        EntraAuthority                = 'https://login.microsoftonline.us'
        StorageSuffix                 = 'blob.core.usgovcloudapi.net'
        ArmTokenResource              = 'https://management.usgovcloudapi.net/'
        MonitorTokenScope             = 'https://monitor.azure.us/.default'
        ExpectedAgentCloudValues      = @('AzureUSGovernment')
        SupportsArcGateway            = $false
        SupportsAutomaticAgentUpgrade = $false
    }
}
