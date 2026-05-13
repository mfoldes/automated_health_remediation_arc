#Requires -Version 5.1

function Set-ArcRgRoleAssignment {
    <#
        .SYNOPSIS
            Assign the Azure Connected Machine Resource Administrator and
            Azure Connected Machine Onboarding roles to a service principal
            on each named Arc resource group.

        .DESCRIPTION
             Setup-AzureSide.ps1 assigns the
            two Arc-related built-in roles on the named Arc resource groups
            -- NOT at subscription scope - so the credential's blast radius
            stays bounded to the resource groups the package is allowed to
            manage.

            Role definition IDs are pinned from Microsoft Learn
            (learn.microsoft.com/azure/role-based-access-control/built-in-roles/management-and-governance):

              Azure Connected Machine Resource Administrator:
                cd570a14-e51a-42ad-bac8-bafd67325302
              Azure Connected Machine Onboarding:
                b64e21ea-ac4e-4cdf-9dc9-5b892992bee7

            The function is idempotent: an existing assignment for
            (ObjectId, RoleDefinitionId, Scope) is kept; a new assignment
            is created only when one is missing.

        .PARAMETER ServicePrincipalObjectId
            The AAD object ID of the SP. NOTE: this is the SP's ObjectId
            (Microsoft Graph), not the application's AppId.

        .PARAMETER SubscriptionId
            Subscription containing the Arc resource groups.

        .PARAMETER ResourceGroupName
            One or more Arc resource group names. Each becomes a separate
            assignment scope. This is documented as the operator's
            ScopedResourceGroups list.

        .PARAMETER RoleDefinitionId
            Override the default role set. Defaults to the two Arc roles
            documented above.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$ServicePrincipalObjectId,

        [Parameter(Mandatory)]
        [string]$SubscriptionId,

        [Parameter(Mandatory)]
        [string[]]$ResourceGroupName,

        [Parameter()]
        [string[]]$RoleDefinitionId = @(
            'cd570a14-e51a-42ad-bac8-bafd67325302',
            'b64e21ea-ac4e-4cdf-9dc9-5b892992bee7'
        )
    )

    foreach ($rg in $ResourceGroupName) {
        $scope = "/subscriptions/$SubscriptionId/resourceGroups/$rg"

        foreach ($roleId in $RoleDefinitionId) {
            $existing = Get-AzRoleAssignment `
                -ObjectId $ServicePrincipalObjectId `
                -RoleDefinitionId $roleId `
                -Scope $scope `
                -ErrorAction SilentlyContinue
            if ($existing) {
                continue
            }

            if (-not $PSCmdlet.ShouldProcess($scope, "New-AzRoleAssignment -RoleDefinitionId $roleId")) {
                continue
            }

            $null = New-AzRoleAssignment `
                -ObjectId $ServicePrincipalObjectId `
                -RoleDefinitionId $roleId `
                -Scope $scope `
                -ErrorAction Stop
        }
    }
}
