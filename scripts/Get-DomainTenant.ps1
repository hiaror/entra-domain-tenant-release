<#
.SYNOPSIS
    Home realm discovery for a domain. Finds whether a domain is claimed by a
    Microsoft Entra tenant, and reports the tenant ID, cloud instance and region.
    Uses public endpoints only. No sign in and no module required.

.DESCRIPTION
    Queries two public Microsoft endpoints:
      getuserrealm.srf      tells you whether the domain is claimed, and how
      openid-configuration  exposes the tenant GUID, cloud instance and region

    NameSpaceType from the realm lookup is read as follows:
      Managed     a tenant holds the domain and signs users in itself
      Federated   a tenant holds the domain and sends sign-in to an external
                  identity provider, whose address appears in AuthURL when
                  the response includes it (observed, not documented)
      Unknown     no tenant holds the domain, so it is free to verify
    A failed lookup, or any other value, is reported as inconclusive.

    Run it against a domain you are trying to add, and optionally against a domain
    already in your own tenant, to see whether they sit in the same directory.

.PARAMETER Domain
    The domain to look up, for example contoso.com.

.PARAMETER CompareDomain
    Optional. A second domain, usually one in your own tenant, to compare against.

.EXAMPLE
    .\Get-DomainTenant.ps1 -Domain contoso.com

.EXAMPLE
    .\Get-DomainTenant.ps1 -Domain contoso.com -CompareDomain destinationtenant.onmicrosoft.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Domain,
    [string]$CompareDomain
)

function Get-RealmInfo {
    param([string]$DomainName)

    $realm  = $null
    $openid = $null

    try {
        $realm = Invoke-RestMethod -Method Get -Uri "https://login.microsoftonline.com/getuserrealm.srf?login=test@$DomainName&json=1" -ErrorAction Stop
    } catch {
        Write-Warning "Realm lookup failed for $DomainName : $($_.Exception.Message)"
    }

    try {
        $openid = Invoke-RestMethod -Method Get -Uri "https://login.microsoftonline.com/$DomainName/v2.0/.well-known/openid-configuration" -ErrorAction Stop
    } catch {
        # A tenant that does not exist returns an error here. Expected for an unclaimed domain.
        $openid = $null
    }

    $tenantId = $null
    if ($openid -and $openid.issuer) {
        $tenantId = ($openid.issuer -split '/')[3]
    }

    [PSCustomObject]@{
        Domain          = $DomainName
        NameSpaceType   = if ($realm)  { $realm.NameSpaceType }      else { "Lookup failed" }
        FederationBrand = if ($realm)  { $realm.FederationBrandName } else { $null }
        AuthURL         = if ($realm)  { $realm.AuthURL }             else { $null }
        TenantId        = $tenantId
        CloudInstance   = if ($openid) { $openid.cloud_instance_name } else { $null }
        RegionScope     = if ($openid) { $openid.tenant_region_scope } else { $null }
    }
}

$primary = Get-RealmInfo -DomainName $Domain
$primary | Format-List

if ($primary.NameSpaceType -eq "Managed") {
    Write-Host "This domain is claimed by a tenant that signs users in itself (Managed). Tenant ID above." -ForegroundColor Yellow
} elseif ($primary.NameSpaceType -eq "Federated") {
    Write-Host "This domain is claimed by a tenant that sends sign-in to an external identity provider (Federated). Tenant ID above." -ForegroundColor Yellow
    if ($primary.FederationBrand) {
        Write-Host "Federation brand: $($primary.FederationBrand)" -ForegroundColor Yellow
    }
    if ($primary.AuthURL) {
        Write-Host "Sign-in is sent to: $($primary.AuthURL)" -ForegroundColor Yellow
    }
} elseif ($primary.NameSpaceType -eq "Unknown") {
    Write-Host "No tenant claims this domain. It is free to verify." -ForegroundColor Green
} else {
    Write-Host "The result is inconclusive (NameSpaceType: $($primary.NameSpaceType)). Run the lookup again before acting on it." -ForegroundColor Red
}

if ($CompareDomain) {
    Write-Host ""
    $compare = Get-RealmInfo -DomainName $CompareDomain
    $compare | Format-List

    if ($primary.TenantId -and $compare.TenantId) {
        if ($primary.TenantId -eq $compare.TenantId) {
            Write-Host "Both domains are in the SAME tenant." -ForegroundColor Green
        } else {
            Write-Host "The domains are in DIFFERENT tenants." -ForegroundColor Yellow
        }
    }
}
