<#
.SYNOPSIS
    Guided release of a custom domain from a Microsoft Entra tenant you administer,
    so it can be verified in another tenant.

.DESCRIPTION
    Connects to the holding tenant with Microsoft Graph PowerShell in a session scoped
    to this PowerShell process, confirms the tenant, lists everything that references
    the domain, and removes the domain when nothing blocks it.

    By design this script does NOT delete or modify users, groups or applications. If
    objects still reference the domain, or a subdomain of it is still in the tenant, it
    reports them and stops, so you can decide how to handle each one. Removing or
    renaming those objects is a deliberate manual step, described in
    docs/04-release-domain.md.

    With -Wait, after the removal it checks once a minute, for up to 30 minutes, until
    the domain is gone from Get-MgDomain and the public realm lookup returns Unknown.

    Run only against a tenant you administer.

.PARAMETER HoldingTenantId
    The tenant GUID that currently holds the domain, from Get-DomainTenant.ps1.

.PARAMETER Domain
    The domain to release, for example contoso.com.

.PARAMETER Wait
    Optional. After the removal, check once a minute for up to 30 minutes until the
    domain has left the tenant and the realm lookup returns Unknown.

.EXAMPLE
    .\Release-Domain.ps1 -HoldingTenantId 11111111-1111-1111-1111-111111111111 -Domain contoso.com

.EXAMPLE
    .\Release-Domain.ps1 -HoldingTenantId 11111111-1111-1111-1111-111111111111 -Domain contoso.com -Wait
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$HoldingTenantId,
    [Parameter(Mandatory)][string]$Domain,
    [switch]$Wait
)

# Requires the Microsoft.Graph module:
#   Install-Module Microsoft.Graph -Scope CurrentUser

Connect-MgGraph -TenantId $HoldingTenantId -Scopes "Domain.ReadWrite.All","Directory.Read.All" -ContextScope Process -NoWelcome

$ctx = Get-MgContext
if (-not $ctx) { throw "Not connected to Microsoft Graph." }
if ($ctx.TenantId -ne $HoldingTenantId) {
    throw "Connected to tenant $($ctx.TenantId), not $HoldingTenantId. Aborting."
}
Write-Host "Connected to tenant $($ctx.TenantId) as $($ctx.Account)." -ForegroundColor Green

$domainObj = Get-MgDomain -DomainId $Domain -ErrorAction Stop
Write-Host ""
Write-Host "Domain: $($domainObj.Id)  IsVerified: $($domainObj.IsVerified)  IsDefault: $($domainObj.IsDefault)  IsInitial: $($domainObj.IsInitial)"

if ($domainObj.IsDefault) {
    Write-Warning "This domain is the tenant default. Set the initial onmicrosoft.com domain as default before removing it."
    return
}

$subdomains = @(Get-MgDomain -All | Where-Object { $_.Id -like "*.$Domain" })
if ($subdomains.Count -gt 0) {
    $subdomains | Select-Object Id, IsVerified | Format-Table -AutoSize
    Write-Warning "Subdomains of $Domain are still in this tenant. Remove them before removing $Domain."
    return
}

$refs  = Get-MgDomainNameReference -DomainId $Domain -All
$count = ($refs | Measure-Object).Count
Write-Host ""
Write-Host "Objects referencing the domain: $count"

if ($count -gt 0) {
    $refs | ForEach-Object {
        [PSCustomObject]@{
            Id   = $_.Id
            Type = $_.AdditionalProperties.'@odata.type'
            Name = $_.AdditionalProperties.displayName
            UPN  = $_.AdditionalProperties.userPrincipalName
        }
    } | Format-Table -AutoSize

    Write-Warning "The domain cannot be removed while these objects reference it."
    Write-Warning "Handle each object first (rename off the domain, or delete if stale)."
    Write-Warning "See docs/04-release-domain.md. This script will not modify those objects."
    return
}

if ($PSCmdlet.ShouldProcess($Domain, "Remove domain from tenant $HoldingTenantId")) {
    try {
        Remove-MgDomain -DomainId $Domain -ErrorAction Stop
    } catch {
        Write-Warning "Remove-MgDomain failed: $($_.Exception.Message)"
        return
    }
    Write-Host "Removal submitted for $Domain." -ForegroundColor Green

    if (-not $Wait) {
        Write-Host "Confirm release with Get-DomainTenant.ps1 -Domain $Domain (expect NameSpaceType Unknown)."
        return
    }

    # A failed forceDelete can stay recorded in the domain state, so this watches for the
    # domain to leave the tenant list rather than reading its state.
    for ($i = 1; $i -le 30; $i++) {
        Start-Sleep -Seconds 60

        $stillThere = [bool](Get-MgDomain -All | Where-Object { $_.Id -eq $Domain })

        try {
            $realmType = (Invoke-RestMethod -Method Get -Uri "https://login.microsoftonline.com/getuserrealm.srf?login=test@$Domain&json=1" -ErrorAction Stop).NameSpaceType
        } catch {
            $realmType = "Lookup failed"
        }

        Write-Host ("{0}  Still in old tenant: {1}  Realm: {2}" -f (Get-Date -Format 'HH:mm'), $stillThere, $realmType)

        if (-not $stillThere -and $realmType -eq "Unknown") {
            Write-Host "Gone from the old tenant." -ForegroundColor Green
            return
        }
    }

    Write-Warning "After 30 minutes $Domain is still listed in the tenant, or the realm lookup is not yet Unknown. Check again later."
}
