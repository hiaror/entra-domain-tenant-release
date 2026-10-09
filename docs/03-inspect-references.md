# Inspect What Uses the Domain

With the holding tenant identified and confirmed as managed, sign in to it and find out what still uses the domain. Every object that references the domain blocks the removal, so you want the full list in front of you before you change anything.

## Connect to the holding tenant

Use the tenant GUID you found during home realm discovery, and sign in with an account that is an administrator of the holding tenant, at least Domain Name Administrator.

```powershell
Connect-MgGraph -TenantId <HOLDING_TENANT_ID> -Scopes "Domain.ReadWrite.All","Directory.Read.All" -ContextScope Process
```

`Domain.ReadWrite.All` lets you read the domain and later remove it. `Directory.Read.All` is requested because, without read access to an object type, the list of references returns only the `id` and `@odata.type` of each object, with no name or user principal name to tell you what it is. If the tenant has never been used with Microsoft Graph PowerShell, you are asked to consent to these permissions for the Microsoft Graph Command Line Tools application on first sign-in. That is expected.

`-ContextScope Process` keeps the sign-in to this PowerShell session only. By default, Microsoft Graph PowerShell caches the sign-in and reuses it across sessions, which is how a session ends up pointed at a tenant you used earlier.

Sign in with an account whose user name is on the initial `onmicrosoft.com` domain, or on another custom domain, not on `yourdomain.com`. Microsoft notes that you cannot delete a domain that your own sign-in name uses.

## Confirm which tenant you are in

Before you trust anything that comes back, check which tenant the session is actually connected to.

```powershell
Get-MgContext | Select-Object TenantId, Account, Scopes | Format-List
```

`TenantId` must match the holding tenant GUID exactly. If you have recently worked in your destination tenant, or in any other tenant, it is easy to end up reading from, and later deleting in, the wrong one. If the GUID does not match, disconnect and connect again:

```powershell
Disconnect-MgGraph
Connect-MgGraph -TenantId <HOLDING_TENANT_ID> -Scopes "Domain.ReadWrite.All","Directory.Read.All" -ContextScope Process
```

Everything from [04-release-domain.md](04-release-domain.md) onwards changes directory objects, so this check is worth the few seconds it takes. [../scripts/Release-Domain.ps1](../scripts/Release-Domain.ps1) makes the same check and aborts if the tenant does not match.

## Format every result

Run the commands below one at a time, or keep the `Format-Table` and `Format-List` at the end of each as shown. In the validated run, a block that sent objects of different shapes to the screen without formatting printed blank lines where the results should have been.

## Check the domain itself

```powershell
Get-MgDomain | Select-Object Id, IsVerified, IsDefault, IsInitial | Format-Table -AutoSize
```

```
Id                            IsVerified IsDefault IsInitial
--                            ---------- --------- ---------
holdingtenant.onmicrosoft.com       True      True      True
yourdomain.com                      True     False     False
```

Read the three columns for `yourdomain.com` like this:

- **IsVerified** should be `True`. Microsoft does not allow a domain name to be verified in more than one tenant, so if it shows `False` here, this tenant is not the one blocking you.
- **IsDefault** must be `False` before the domain can be removed. The default domain is the one new users get unless you choose otherwise, and a tenant cannot be left without one.
- **IsInitial** is `True` only for the `onmicrosoft.com` domain created with the tenant. That domain can never be removed, and it is where renamed objects are moved to during the release.

If `yourdomain.com` is the default, make the initial domain the default first:

```powershell
Update-MgDomain -DomainId "holdingtenant.onmicrosoft.com" -BodyParameter @{ isDefault = $true }
```

Also look for subdomains of the domain in the same list, such as `sub.yourdomain.com`. Microsoft lists "Domain has associated subdomains" as an error when removing a domain, so any subdomain verified in this tenant has to be removed first.

## List what references the domain

```powershell
$refs = Get-MgDomainNameReference -DomainId "yourdomain.com" -All
"References found: $(($refs | Measure-Object).Count)"

$refs | ForEach-Object {
    [PSCustomObject]@{
        Id   = $_.Id
        Type = $_.AdditionalProperties.'@odata.type'
        Name = $_.AdditionalProperties.displayName
        UPN  = $_.AdditionalProperties.userPrincipalName
    }
} | Format-Table -AutoSize
```

The type, display name and user principal name sit inside `AdditionalProperties`, so they have to be expanded as above. In the validated run, the list held one object:

```
References found: 1

Id                                   Type                  Name        UPN
--                                   ----                  ----        ---
33333333-3333-3333-3333-333333333333 #microsoft.graph.user Old Account user@yourdomain.com
```

The type tells you where the reference lives:

- `#microsoft.graph.user`: the domain appears in the user principal name, the `mail` attribute or the proxy addresses.
- `#microsoft.graph.group`: the domain appears in the group's `mail` attribute.
- `#microsoft.graph.application`: the domain appears in the application's identifier URIs.

For a user, look at the account in detail before deciding what to do with it:

```powershell
Get-MgUser -UserId <OBJECT_ID> -Property DisplayName,UserPrincipalName,Mail,AccountEnabled,CreatedDateTime,AssignedLicenses,ProxyAddresses |
    Select-Object DisplayName, UserPrincipalName, Mail, AccountEnabled, CreatedDateTime,
        @{ Name = 'Licenses'; Expression = { $_.AssignedLicenses.Count } },
        @{ Name = 'ProxyAddresses'; Expression = { $_.ProxyAddresses -join '; ' } } |
    Format-List
```

In the validated run, this showed a user created in 2018, unlicensed and still enabled, whose proxy addresses held `SMTP:user@yourdomain.com` as the primary address alongside a secondary address on `holdingtenant.onmicrosoft.com`. A fuller sanitised capture is in [../logs/release-failure.log](../logs/release-failure.log). A user can also appear here with a user principal name already on `onmicrosoft.com`, because one of its proxy addresses is still on the domain.

## Reading the result

Microsoft documents that attempts to delete a domain fail while any resource or object still depends on it. Any reference at all therefore blocks the normal removal. Keep the list, because each object on it has to be renamed off the domain or deleted first, and [04-release-domain.md](04-release-domain.md) walks through both.

Zero references, no subdomains, and a domain that is not the default mean nothing on this list still stands in the way, and you can go straight to the clean case at the start of [04-release-domain.md](04-release-domain.md).
