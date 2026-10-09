# Microsoft Entra ID: Finding and Releasing a Domain Stuck in Another Tenant, Using PowerShell

## Overview

A custom domain in Microsoft Entra ID can only be verified in one tenant at a time. If the domain is already verified in another tenant, the verification in your tenant fails, and the admin center gives no indication of which tenant is holding it. Support cases for this scenario are often misrouted, because the holding tenant is not visible to the person who needs the domain.

This repository documents a fast, self-service way to deal with it using Microsoft Graph PowerShell. The starting point is **home realm discovery**, a public, unauthenticated lookup that reveals whether a domain is claimed by a tenant, how that tenant handles sign-in, which cloud and region it sits in, and the tenant GUID itself. From there it covers how to release the domain from the holding tenant when you are an administrator of it, including the case where an old user that still carries the domain in its email addresses blocks the release, and how to verify the domain in the destination tenant in minutes.

Everything here was carried out and validated on a real tenant. The identifiers in the logs are sanitised. Throughout, `yourdomain.com` stands for the custom domain, `holdingtenant.onmicrosoft.com` and `destinationtenant.onmicrosoft.com` for the initial domains of the tenant that holds it and the tenant that wants it, and values in angle brackets, such as `<HOLDING_TENANT_ID>`, for identifiers you take from your own environment.

## Why This Exists

When a domain is stuck in another tenant, the error you see is about verification failing in your own tenant. Nothing on that screen tells you where the domain actually is, so the natural first step is to raise a support case, and those cases frequently stall. The information you need to move quickly is public and takes seconds to retrieve, but it is not obvious that it exists or how to read it. This repository brings the discovery lookups and the Graph PowerShell release path into one place, with the real output at each step so you can confirm you are looking at the same situation.

## Who This Is For

Microsoft 365 and Entra administrators who need to add a custom domain and find it is already verified in a tenant they do not control, or do not recognise. It is most useful if you suspect you created or inherited the holding tenant yourself, for example an old trial, a lab, or a tenant set up years ago, since in that case you can often release the domain entirely on your own with the steps here.

## What This Covers

- Home realm discovery: confirming whether another tenant holds a domain, whether that tenant signs users in itself or through an external identity provider, and reading the tenant GUID, cloud instance and region from public endpoints
- How to tell a managed tenant from an unmanaged one, why that decides whether external admin takeover is possible, and the takeover error seen against a managed tenant
- Connecting to the holding tenant with Microsoft Graph PowerShell in a session scoped to one process, confirming the tenant, and listing what references the domain
- Clearing a user whose email addresses still carry the domain, with the permanent delete route validated here
- forceDelete: what it changes, why an accepted request is not a finished one, and how to read its status
- Verifying the released domain in the destination tenant with no DNS change when the verification record is already in place
- Known issues met along the way, and the output at each stage, sanitised, so you can compare against your own

## Repository Structure

```
entra-domain-tenant-release/
├── docs/
│   ├── 01-home-realm-discovery.md   Find the holding tenant, its sign-in type, cloud and region
│   ├── 02-managed-vs-unmanaged.md   Why the tenant type decides your options, and the takeover error
│   ├── 03-inspect-references.md     Connect with Graph, confirm the tenant, list what uses the domain
│   ├── 04-release-domain.md         Clear the blocking user, remove the domain, forceDelete in full
│   └── 05-verify-new-tenant.md      Confirm the release, then verify in the destination tenant
├── logs/
│   ├── before-discovery.log         Sanitised realm, OpenID and tenant comparison output
│   ├── release-failure.log          Sanitised forceDelete accepted, then failed on a referenced user
│   └── after-success.log            Sanitised user deletion, domain removal and verification
├── scripts/
│   ├── Get-DomainTenant.ps1         Home realm discovery for a domain, no sign-in required
│   └── Release-Domain.ps1           Guided release from a holding tenant you administer
├── .gitignore
├── LICENSE
└── README.md
```

## Prerequisites

- The destination tenant, where you want the domain, and administrator access to it.
- For the release, administrator access to the holding tenant as well. Microsoft Learn lists Domain Name Administrator as the least privileged role for removing a domain, forceDelete included.
- To delete or rename a user in the holding tenant, at least User Administrator. A user who holds a privileged administrator role needs a higher role to act on it. To change a user's addresses through Exchange Online, an Exchange admin role, such as Exchange Administrator or Exchange Recipient Administrator.
- If you created the holding tenant yourself, its Global Administrator covers all of the above.
- The Microsoft Graph PowerShell SDK. Install with `Install-Module Microsoft.Graph -Scope CurrentUser`.
- For the home realm discovery step, nothing at all. The lookups are public and need no module and no sign-in.

## Step 1: Home Realm Discovery

This is the step that makes everything else possible, and it needs no credentials. Two public endpoints tell you almost everything about where a domain lives.

The user realm lookup tells you whether the domain is claimed by a tenant:

```powershell
Invoke-RestMethod "https://login.microsoftonline.com/getuserrealm.srf?login=test@yourdomain.com&json=1"
```

Read the `NameSpaceType` field:

- `Managed` means a tenant owns the domain and signs users in itself.
- `Federated` means a tenant owns the domain and sends sign-in to an external identity provider, such as AD FS. The domain is equally taken, and in observed responses it also carries the provider's address in `AuthURL`.
- `Unknown` means no tenant claims the domain, and it is free to verify.

`Managed` here describes sign-in, not whether the tenant has an administrator. That question is Step 2.

The OpenID configuration reveals the tenant GUID, the cloud instance and the region:

```powershell
$cfg = Invoke-RestMethod "https://login.microsoftonline.com/yourdomain.com/v2.0/.well-known/openid-configuration"
$cfg.issuer              # contains the holding tenant GUID
$cfg.cloud_instance_name # microsoftonline.com for the worldwide commercial cloud
$cfg.tenant_region_scope # for example NA, EU, AS
```

Run both against the domain you are trying to add, and against a domain in your own tenant, such as `destinationtenant.onmicrosoft.com`, and compare. If the GUIDs differ, the domain is in a separate directory, and the GUID you now have is the holding tenant. See [docs/01-home-realm-discovery.md](docs/01-home-realm-discovery.md), or use [scripts/Get-DomainTenant.ps1](scripts/Get-DomainTenant.ps1) to run all of this in one step.

## Step 2: Managed or Unmanaged

The tenant type decides your options, so establish it before anything else. See [docs/02-managed-vs-unmanaged.md](docs/02-managed-vs-unmanaged.md).

An **unmanaged** tenant, created automatically when someone signed up for a service with an address on the domain and never had an administrator appointed, can be taken over from the destination tenant through external admin takeover. A **managed** tenant, one with a real administrator, cannot. If adding the domain in the destination tenant shows a masked administrator account for the tenant that holds it, or an external takeover attempt returns an error rather than moving the domain, the tenant is managed, and your route is to release the domain from inside it as an administrator. Both signals appeared in the validated run, and the takeover error is described in doc 02.

## Step 3: Inspect What Uses the Domain

Connect to the holding tenant, confirm the session is in the right tenant, and list every object that references the domain. See [docs/03-inspect-references.md](docs/03-inspect-references.md).

```powershell
Connect-MgGraph -TenantId <HOLDING_TENANT_ID> -Scopes "Domain.ReadWrite.All","Directory.Read.All" -ContextScope Process
Get-MgContext | Select-Object TenantId, Account | Format-List

Get-MgDomain | Select-Object Id, IsVerified, IsDefault, IsInitial | Format-Table -AutoSize

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

Keep the `Format-Table` and `Format-List` at the end of each command. In the validated run, the first version of this block sent objects of different shapes to the screen unformatted and printed blank lines (see Known Issues).

The domain must not be the default. If it is, set the initial `onmicrosoft.com` domain as default first. The reference list shows the users, groups and applications still using the domain. Microsoft documents that the removal fails while any object still depends on the domain, so anything listed has to be dealt with first. Zero references is necessary but not always sufficient: Microsoft also lists "Domain has associated subdomains" as a removal error, so any subdomain of the domain that is verified in the same tenant has to be removed first.

## Step 4: Release the Domain

With no references and no subdomains, the normal removal is enough:

```powershell
Remove-MgDomain -DomainId "yourdomain.com"
```

In the validated run, the reference list held one user: created in 2018, unlicensed, still enabled, with `SMTP:user@yourdomain.com` among its proxy addresses. Because Microsoft documents that the removal fails while any object depends on the domain, `Remove-MgDomain` was not run at that point. forceDelete was tried instead. It was accepted without error at 19:54. The failure was first seen when the domain state was read at 19:59, and it named the user as the conflicting object. See [logs/release-failure.log](logs/release-failure.log). The error text does not mention Exchange. Linking it to Exchange is our reading, based on the user's proxy addresses and Microsoft's statement that forceDelete needs references where Exchange is the provisioning service to be cleared first.

Two ways to clear a blocking user:

- **Rename it.** Move its sign-in name and email addresses to the initial `onmicrosoft.com` domain. This keeps the account, but it was not validated here.
- **Delete it permanently.** This is the route validated in this repository, suitable for a stale, unlicensed account with nothing to lose. A single delete moves the account to the recycle bin, where Microsoft keeps it with its properties for 30 days and where it can still block the domain, so delete it from the recycle bin as well.

Deleting a user needs more than the Step 3 scopes. Reconnect, and confirm the tenant before changing anything:

```powershell
Disconnect-MgGraph
Connect-MgGraph -TenantId <HOLDING_TENANT_ID> -Scopes "Domain.ReadWrite.All","Directory.Read.All","User.ReadWrite.All","User.DeleteRestore.All" -ContextScope Process
Get-MgContext | Select-Object TenantId, Account | Format-List
```

`TenantId` must be the holding tenant GUID. Then delete the user in two stages, recount, and remove the domain:

```powershell
Remove-MgUser -UserId <OBJECT_ID>
Start-Sleep -Seconds 30
Remove-MgDirectoryDeletedItem -DirectoryObjectId <OBJECT_ID>

$count = (Get-MgDomainNameReference -DomainId "yourdomain.com" -All | Measure-Object).Count
"References found: $count"
if ($count -eq 0) { Remove-MgDomain -DomainId "yourdomain.com" }
```

In the validated run, the domain left the holding tenant and the realm lookup returned `Unknown` within about a minute. See [logs/after-success.log](logs/after-success.log).

forceDelete is the alternative when there are many referenced objects to rename at once. It updates the `userPrincipalName`, `mail` and `proxyAddresses` of users, the `mail` of groups and the `identifierUris` of applications to the initial `onmicrosoft.com` domain, then deletes the domain. It disables every account it renames unless you set `disableUserAccounts` to `false`:

```powershell
$body = @{ disableUserAccounts = $false } | ConvertTo-Json
Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/domains/yourdomain.com/forceDelete" -Body $body -ContentType "application/json"
```

**Accepted is not done.** forceDelete runs in the background, so a call that returns without an error tells you only that the request was accepted. Read the domain state afterwards, and test the status with `-like 'Failed*'` rather than `-eq 'Failed'`, because in the validated run the reason came back inside the status string itself:

```powershell
$state = (Get-MgDomain -DomainId "yourdomain.com").State
if ($state.Status -like 'Failed*') { Write-Warning $state.Status }
```

forceDelete also requires references where Exchange is the provisioning service to be cleared first, and on our reading this is the precondition the failure hit. The full walkthrough, including both routes, is in [docs/04-release-domain.md](docs/04-release-domain.md), and [scripts/Release-Domain.ps1](scripts/Release-Domain.ps1) runs the guided sequence.

## Step 5: Verify in the Destination Tenant

Once the realm lookup returns `Unknown`, the domain is free. The lookup can lag the removal, so recheck it before you verify. Verify the domain in the destination tenant. If the verification TXT record is already live in DNS, this completes with no DNS change at all. See [docs/05-verify-new-tenant.md](docs/05-verify-new-tenant.md).

```powershell
Disconnect-MgGraph
Connect-MgGraph -TenantId <DESTINATION_TENANT_ID> -Scopes "Domain.ReadWrite.All" -ContextScope Process
Get-MgContext | Select-Object TenantId, Account | Format-List
Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/domains/yourdomain.com/verify"
Get-MgDomain -DomainId "yourdomain.com" | Select-Object Id, IsVerified | Format-Table -AutoSize
```

`IsVerified` of `True` means the domain now belongs to your tenant. In the validated run, verification succeeded about four minutes after the removal, with no DNS change, and the returned domain showed an empty `supportedServices`, because verification proves ownership and does not configure any service.

## Validated Environment

| Component | Detail |
| --- | --- |
| Clouds | Both tenants in the worldwide commercial cloud (`microsoftonline.com`) |
| Holding tenant | Created in 2018 and dormant for years |
| Blocking object | One unlicensed user whose primary SMTP proxy address was still on the domain |
| Operating system | Windows 11 Pro |
| PowerShell | PowerShell 7.6.6 |
| Graph module | Microsoft.Graph 2.36.1 |
| Sign-in | Interactive browser sign-in with WAM disabled, `-ContextScope Process` |
| Date | October 2026 |

## Result

The domain is released from the holding tenant and verified in the destination tenant, ready to use. Throughout the release, no DNS, MX or mail records are touched, so email already flowing on the domain through another provider continues uninterrupted until you choose to move it. If the holding tenant's Exchange Online still receives mail for the domain, that mail stops when the domain is removed, so move that mail first.

## Known Issues

- **Device code sign-in failed on a corporate-managed device.** During an earlier attempt on a different, corporate-managed Windows device, `Connect-MgGraph -UseDeviceAuthentication` failed with `DeviceCodeCredential authentication failed: Object reference not set to an instance of an object`. On that device, `Set-MgGraphOption -DisableLoginByWAM $true` followed by a normal browser sign-in without `-UseDeviceAuthentication` worked. The release itself ran on the machine in Validated Environment, with WAM disabled. The setting persists across sessions, so revert it afterwards with `Set-MgGraphOption -DisableLoginByWAM $false`. Microsoft Learn now notes that this switch only takes effect with a custom ClientId, so on current module versions it may have no effect, and signing in from a machine that is not corporate-managed is the other option.
- **Mixed objects can print as blank lines.** Objects of different shapes sent to the screen in one block can render as blank lines, which is how the first version of the Step 3 block failed here. Pipe each result to `Format-Table` or `Format-List`.
- **forceDelete accepted is not forceDelete done.** The call can return without an error while the operation later fails, and the failure shows only when you read the domain state. See [docs/04-release-domain.md](docs/04-release-domain.md).
- **A cached session can belong to the wrong tenant.** By default, Microsoft Graph PowerShell caches the sign-in across sessions. Connect with `-ContextScope Process` and check `Get-MgContext` before any change.

## Safety Notes

- The home realm discovery lookups are read-only and public. They change nothing and reveal only what Microsoft already exposes to anyone.
- forceDelete and permanent user deletion are powerful operations against your own tenant. Run them only against a tenant you administer, and only after the reference list has shown you exactly what will be renamed or removed.
- Permanent deletion of a user cannot be undone once the object is removed from the recycle bin. Confirm the account carries nothing you need before deleting it.
- Releasing the domain does not delete the holding tenant, and leaves its initial `onmicrosoft.com` domain in place.
- None of the steps change DNS records, so mail on the domain that flows through another provider is unaffected by the release itself. If the holding tenant's Exchange Online still receives mail for the domain, that mail stops when the domain is removed, so move it first.

## Disclaimer

Provided as-is for reference and learning purposes. The release steps act on live directory objects, so test the approach in a non-production tenant before applying it to one that matters. Microsoft Graph behaviour and API versions change over time, so confirm the current guidance in the Microsoft documentation.
