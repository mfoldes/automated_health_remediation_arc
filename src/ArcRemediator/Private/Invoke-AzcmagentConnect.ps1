#Requires -Version 5.1

function Invoke-AzcmagentConnect {
    <#
        .SYNOPSIS
            Run 'azcmagent connect' to re-onboard the local machine after
            an Expired delete, preserving the original resource identity.

        .DESCRIPTION
            and the design:

              * Prefer --service-principal-cert-thumbprint when the
                ArcCredential is a Certificate; this keeps NO secret
                material on the command line (the agent reads the
                private key from the local Windows certificate store
                using the thumbprint).

              * For ClientSecret credentials, write a TEMP YAML config
                file under %ProgramData%\ArcRemediator with restricted
                ACLs (SYSTEM + Administrators only), pass --config
                <path>, and DELETE the file in the finally block. The
                secret is therefore never on the command line and
                never persists past the connect attempt.

              * Forward proxy / private-link / Arc Gateway settings
                only when the active cloud profile permits them. In
                particular, --gateway-id is NEVER forwarded when
                SupportsArcGateway=$false (DoD/IL5).

              * Forward --enable-automatic-upgrade ONLY when both
                SupportsAutomaticAgentUpgrade=$true on the profile AND
                the caller passes -EnableAutomaticUpgrade. The agent
                rejects this flag on unsupported clouds.

            The function never echoes the credential block back in
            exceptions; secret-bearing fields ($Credential.ClientSecret,
            private key bytes) are scrubbed from any thrown message.

        .PARAMETER CloudProfile
            From Get-CloudProfile. Provides AzcmagentCloud + capability
            flags.

        .PARAMETER Credential
            ArcCredential block (TenantId, ClientId, CredentialType,
            ClientSecret OR CertificateThumbprint).

        .PARAMETER SubscriptionId
            Subscription to onboard into.

        .PARAMETER ResourceGroupName
            Resource group to onboard into.

        .PARAMETER MachineName
            Resource name. Reused from the original ARM resource to
            preserve identity across delete/rejoin.

        .PARAMETER Location
            Azure region. Reused from the original ARM resource.

        .PARAMETER ProxyUrl
            Optional proxy URL.

        .PARAMETER PrivateLinkScopeResourceId
            Optional ARM ID of the Arc private link scope.

        .PARAMETER ArcGatewayResourceId
            Optional ARM ID of the Arc Gateway. IGNORED when the cloud
            profile reports SupportsArcGateway=$false.

        .PARAMETER EnableAutomaticUpgrade
            Pass-through to the agent's --enable-automatic-upgrade flag.
            IGNORED when SupportsAutomaticAgentUpgrade=$false.

        .PARAMETER TimeoutSec
            Process timeout. Default 300 s; connect can take several
            minutes on slow networks.

        .PARAMETER AzcmagentPath
            Override path for tests.

        .OUTPUTS
            PSCustomObject with:
              ProcessResult (the Invoke-Azcmagent return value)
              UsedConfigFile (bool) - $true if a temp config file was used
              GatewayHonored (bool) - $true if --gateway-id was forwarded
              AutomaticUpgradeHonored (bool) - $true if the flag was forwarded
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUsePSCredentialType', '',
        Justification = 'Credential is a config block (TenantId/ClientId/CredentialType/ClientSecret/CertificateThumbprint), not a PSCredential.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
        Justification = 'No SecureString conversion happens here; secrets stay as plain config-file bytes that are written with restricted ACLs and deleted in the finally block.')]
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [PSObject]$CloudProfile,
        [Parameter(Mandatory)] [PSObject]$Credential,
        [Parameter(Mandatory)] [string]$SubscriptionId,
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$MachineName,
        [Parameter(Mandatory)] [string]$Location,
        [Parameter()] [string]$ProxyUrl,
        [Parameter()] [string]$PrivateLinkScopeResourceId,
        [Parameter()] [string]$ArcGatewayResourceId,
        [Parameter()] [switch]$EnableAutomaticUpgrade,
        [Parameter()] [int]$TimeoutSec = 300,
        [Parameter()] [string]$AzcmagentPath
    )

    if (-not $Credential.TenantId) { throw 'Invoke-AzcmagentConnect: Credential.TenantId is required.' }
    if (-not $Credential.ClientId) { throw 'Invoke-AzcmagentConnect: Credential.ClientId is required.' }
    if (-not $Credential.CredentialType) { throw 'Invoke-AzcmagentConnect: Credential.CredentialType is required.' }

    $argv = New-Object System.Collections.Generic.List[string]
    $argv.Add('connect')
    $argv.Add('--subscription-id'); $argv.Add($SubscriptionId)
    $argv.Add('--resource-group'); $argv.Add($ResourceGroupName)
    $argv.Add('--resource-name'); $argv.Add($MachineName)
    $argv.Add('--location'); $argv.Add($Location)
    $argv.Add('--cloud'); $argv.Add([string]$CloudProfile.AzcmagentCloud)
    $argv.Add('--tenant-id'); $argv.Add($Credential.TenantId)
    $argv.Add('--service-principal-id'); $argv.Add($Credential.ClientId)

    $configPath = $null
    $usedConfigFile = $false
    $gatewayHonored = $false
    $autoUpgradeHonored = $false

    try {
        switch ($Credential.CredentialType) {
            'Certificate' {
                if (-not $Credential.CertificateThumbprint) {
                    throw 'Invoke-AzcmagentConnect: CredentialType=Certificate but CertificateThumbprint is empty.'
                }
                $argv.Add('--service-principal-cert-thumbprint')
                $argv.Add([string]$Credential.CertificateThumbprint)
            }
            'ClientSecret' {
                if (-not $Credential.ClientSecret) {
                    throw 'Invoke-AzcmagentConnect: CredentialType=ClientSecret but ClientSecret is empty.'
                }
                $configPath = New-RestrictedTempConfig -Credential $Credential `
                    -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName `
                    -MachineName $MachineName -Location $Location `
                    -AzcmagentCloud ([string]$CloudProfile.AzcmagentCloud)
                $argv.Add('--config')
                $argv.Add($configPath)
                $usedConfigFile = $true
            }
            default {
                throw "Invoke-AzcmagentConnect: Unsupported CredentialType '$($Credential.CredentialType)'. Expected 'Certificate' or 'ClientSecret'."
            }
        }

        if ($ProxyUrl) {
            $argv.Add('--proxy-url'); $argv.Add($ProxyUrl)
        }
        if ($PrivateLinkScopeResourceId) {
            $argv.Add('--private-link-scope'); $argv.Add($PrivateLinkScopeResourceId)
        }
        $profileSupportsGw = $false
        if ($CloudProfile.PSObject.Properties.Name -contains 'SupportsArcGateway') {
            $profileSupportsGw = [bool]$CloudProfile.SupportsArcGateway
        }
        if ($ArcGatewayResourceId -and $profileSupportsGw) {
            $argv.Add('--gateway-id'); $argv.Add($ArcGatewayResourceId)
            $gatewayHonored = $true
        }
        $profileSupportsUpgrade = $false
        if ($CloudProfile.PSObject.Properties.Name -contains 'SupportsAutomaticAgentUpgrade') {
            $profileSupportsUpgrade = [bool]$CloudProfile.SupportsAutomaticAgentUpgrade
        }
        if ($EnableAutomaticUpgrade -and $profileSupportsUpgrade) {
            $argv.Add('--enable-automatic-upgrade')
            $autoUpgradeHonored = $true
        }

        if (-not $PSCmdlet.ShouldProcess($MachineName, 'azcmagent connect')) {
            return [PSCustomObject]@{
                ProcessResult = $null
                UsedConfigFile = $usedConfigFile
                GatewayHonored = $gatewayHonored
                AutomaticUpgradeHonored = $autoUpgradeHonored
                WhatIf = $true
            }
        }

        $invokeArgs = @{
            Arguments = $argv.ToArray()
            TimeoutSec = $TimeoutSec
        }
        if ($AzcmagentPath) { $invokeArgs.AzcmagentPath = $AzcmagentPath }
        $proc = Invoke-Azcmagent @invokeArgs

        return [PSCustomObject]@{
            ProcessResult = $proc
            UsedConfigFile = $usedConfigFile
            GatewayHonored = $gatewayHonored
            AutomaticUpgradeHonored = $autoUpgradeHonored
            WhatIf = $false
        }
    } finally {
        if ($configPath -and (Test-Path -LiteralPath $configPath)) {
            try {
                Remove-Item -LiteralPath $configPath -Force -ErrorAction Stop
            } catch {
                # Best-effort cleanup; the file has restricted ACLs so a
                # cleanup miss leaks only to SYSTEM + Administrators, which
                # is the same blast radius as the running scheduled task.
                $null = $_
            }
        }
    }
}

function New-RestrictedTempConfig {
    <#
        .SYNOPSIS
            Write a short-lived azcmagent connect config file under
            %ProgramData%\ArcRemediator\temp with ACLs restricted to
            SYSTEM and BUILTIN\Administrators.

        .DESCRIPTION
            The file holds the SP secret in YAML form for the
            ClientSecret credential path. After this function returns,
            the caller is responsible for deleting the file - which
            Invoke-AzcmagentConnect does in its finally block.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUsePSCredentialType', '',
        Justification = 'Credential is a config block (TenantId/ClientId/CredentialType/ClientSecret/CertificateThumbprint), not a PSCredential.')]
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [PSObject]$Credential,
        [Parameter(Mandatory)] [string]$SubscriptionId,
        [Parameter(Mandatory)] [string]$ResourceGroupName,
        [Parameter(Mandatory)] [string]$MachineName,
        [Parameter(Mandatory)] [string]$Location,
        [Parameter(Mandatory)] [string]$AzcmagentCloud
    )

    $tempDir = Join-Path $env:ProgramData 'ArcRemediator\temp'
    if (-not (Test-Path -LiteralPath $tempDir)) {
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    }

    $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $filename = "azcmagent-connect-$stamp-$([guid]::NewGuid().ToString('N')).yaml"
    $path = Join-Path $tempDir $filename

    $content = @"
serviceprincipal_id: $($Credential.ClientId)
serviceprincipal_secret: $($Credential.ClientSecret)
tenant_id: $($Credential.TenantId)
subscription_id: $SubscriptionId
resource_group: $ResourceGroupName
resource_name: $MachineName
location: $Location
cloud: $AzcmagentCloud
"@

    if (-not $PSCmdlet.ShouldProcess($path, 'Write azcmagent connect config')) {
        return $path
    }

    # Restrict ACL to SYSTEM + BUILTIN\Administrators + the current process
    # identity. The ACL is built BEFORE the file is created so the
    # FileStream constructor can apply it atomically -- the file is born
    # with restricted permissions and no TOCTOU window exists between
    # creation and ACL application. In production the remediator runs as
    # SYSTEM so the third entry is redundant; in dev/test the current
    # user keeps the rights needed to delete the file in the finally
    # block on the calling function. Inheritance is disabled
    # (SetAccessRuleProtection $true, do-not-copy=$false) so no
    # inherited entry can widen access.
    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    $system = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-18'
    $admins = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544'
    $current = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $rights = [System.Security.AccessControl.FileSystemRights]::FullControl
    $type = [System.Security.AccessControl.AccessControlType]::Allow
    $acl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($system, $rights, $type)))
    $acl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($admins, $rights, $type)))
    if ($current -and $current.Value -ne $system.Value) {
        $acl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($current, $rights, $type)))
    }

    # Create the file atomically with the restricted ACL. CreateNew
    # ensures we never overwrite an existing file (prevents symlink /
    # overwrite attacks). FileShare::None locks the file exclusively
    # while we write the secret content.
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($content)
    $fs = $null
    try {
        $fs = [System.IO.FileStream]::new(
            $path,
            [System.IO.FileMode]::CreateNew,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            [System.IO.FileShare]::None,
            4096,
            [System.IO.FileOptions]::None,
            $acl
        )
        $fs.Write($bytes, 0, $bytes.Length)
        $fs.Flush()
    } finally {
        if ($fs) { $fs.Dispose() }
    }

    return $path
}
