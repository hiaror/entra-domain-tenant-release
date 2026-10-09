# Release the Domain

This is the step that changes the holding tenant. Work through it only in a tenant you administer, and only after the reference list from [03-inspect-references.md](03-inspect-references.md) has shown you exactly what will be renamed or removed.

## What happened in the validated run

| Time | Event |
| --- | --- |
| 19:54 | forceDelete submitted with `disableUserAccounts` set to `false`. The call was accepted with no error. |
| 19:55 and 19:57 | The domain was still in the holding tenant and the realm lookup still returned `Managed`. These checks did not read the domain state. |
| 19:59 | The domain state was read for the first time. It showed operation `ForceDelete` with a status beginning `Failed. Reason =`, naming the user as the conflicting object. When the operation actually failed is not known. |
| After 19:59 | Reconnected with the user scopes, deleted the user, waited 30 seconds, deleted it from the recycle bin, recounted the references (0), then ran `Remove-MgDomain`. |
| 20:04 | The domain had left the holding tenant and the realm lookup returned `Unknown`, within about a minute of the removal. |
| 20:08 | Verification in the destination tenant succeeded, with no DNS change. |

`Remove-MgDomain` was not run while the reference existed. The sanitised captures are in [../logs/release-failure.log](../logs/release-failure.log) and [../logs/after-success.log](../logs/after-success.log).

## The clean case: nothing references the domain

If the reference count is zero, no subdomain of the domain is in the tenant, and the domain is not the default, the normal removal is all you need:

```powershell
Remove-MgDomain -DomainId "yourdomain.com"
```

It returns no output on success. Confirm that the domain has gone from the tenant list:

```powershell
Get-MgDomain | Select-Object Id, IsVerified, IsDefault | Format-Table -AutoSize
```

[../scripts/Release-Domain.ps1](../scripts/Release-Domain.ps1) runs this whole sequence. It connects to the holding tenant in a session scoped to one PowerShell process, aborts if the session is in any other tenant, stops if the domain is the default or a subdomain of it is still in the tenant, lists the references, and removes the domain only when there are none. It asks for confirmation before the removal and accepts `-WhatIf`. With `-Wait`, it then checks once a minute, for up to 30 minutes, until the domain has left the tenant and the realm lookup returns `Unknown`.

```powershell
.\scripts\Release-Domain.ps1 -HoldingTenantId <HOLDING_TENANT_ID> -Domain yourdomain.com -Wait
```

By design the script never touches users, groups or applications. If anything references the domain it lists the objects and stops, so you can deal with them using the steps below.

## When a user still carries the domain

A tenant that has sat dormant for years rarely comes back clean. In the validated run, the one reference was a user created in 2018, unlicensed and still enabled, whose primary SMTP proxy address was still on the domain.

Microsoft documents that attempts to delete a domain fail while any resource or object still depends on it, so `Remove-MgDomain` was not run at that point. forceDelete, which renames referencing objects for you, was tried instead:

```powershell
$body = @{ disableUserAccounts = $false } | ConvertTo-Json

Invoke-MgGraphRequest -Method POST `
    -Uri "https://graph.microsoft.com/v1.0/domains/yourdomain.com/forceDelete" `
    -Body $body `
    -ContentType "application/json"
```

The call was accepted with no error. The failure was first seen when the domain state was read at 19:59, with the reason inside the status string itself. The earlier checks did not read the state, so when the operation actually failed is not known:

```
Status: Failed. Reason = Cannot delete the domain currently referenced by at least 1 objects. Conflicting object User/33333333-3333-3333-3333-333333333333.
```

The object ID after `User/` is the account you need to deal with.

The error names the conflicting user but does not mention Exchange. Linking it to Exchange is our reading, not something the error states. It rests on two things: the user's primary SMTP address was still on the domain in its proxy addresses, and Microsoft states that forceDelete needs any references where Exchange is the provisioning service to be updated or removed first.

There are two ways to clear the user, depending on whether the account is worth keeping. Route B is the one validated in this repository.

## Reconnect with the user scopes

The scopes used so far cover domains and reading the directory. Renaming or deleting a user needs more. Disconnect, reconnect in a process-scoped session with the user scopes added, and confirm the tenant before changing anything:

```powershell
Disconnect-MgGraph
Connect-MgGraph -TenantId <HOLDING_TENANT_ID> -Scopes "Domain.ReadWrite.All","Directory.Read.All","User.ReadWrite.All","User.DeleteRestore.All" -ContextScope Process
Get-MgContext | Select-Object TenantId, Account | Format-List
```

`TenantId` must be the holding tenant GUID. `User.ReadWrite.All` covers renaming the user and the first delete, and `User.DeleteRestore.All` covers the permanent delete from the recycle bin.

The role matters as well. Microsoft Learn lists at least User Administrator for deleting or renaming an ordinary user, and a user who holds a privileged administrator role needs a higher role to act on it. Changing addresses through Exchange Online needs an Exchange admin role, such as Exchange Administrator or Exchange Recipient Administrator. If you created the holding tenant yourself, its Global Administrator covers all of it.

## Route A: rename the user off the domain (not validated here)

This is the non-destructive option, for an account that is real and worth keeping. It was not exercised in the validated run, so treat these commands as a starting point and check each result.

First move the sign-in name to the initial `onmicrosoft.com` domain:

```powershell
Update-MgUser -UserId <OBJECT_ID> -UserPrincipalName "user@holdingtenant.onmicrosoft.com"
```

Then deal with the email addresses. Microsoft Graph treats `proxyAddresses` as read-only, so the addresses on a mailbox have to be changed in Exchange Online. Make the `onmicrosoft.com` address primary, then remove the old one:

```powershell
Connect-ExchangeOnline -Organization holdingtenant.onmicrosoft.com

Set-Mailbox -Identity <OBJECT_ID> -WindowsEmailAddress "user@holdingtenant.onmicrosoft.com"
Set-Mailbox -Identity <OBJECT_ID> -EmailAddresses @{ remove = "smtp:user@yourdomain.com" }

Get-Mailbox -Identity <OBJECT_ID> | Select-Object -ExpandProperty EmailAddresses
```

Per the Set-Mailbox reference, `-WindowsEmailAddress` updates the primary address only when the mailbox is not subject to an email address policy, that is when its `EmailAddressPolicyEnabled` property is `False`. If the primary address has not changed, check that property first.

Repeat the remove for every address on the domain that the last command still lists. If Exchange Online PowerShell cannot find a mailbox for the account at all, there is nothing for it to edit, and for a stale account Route B is the practical option.

## Route B: permanently delete a stale account (validated here)

Use this only when the account is stale, unlicensed, and carries nothing you need. Permanent deletion cannot be undone. This is the route used in the validated run.

`Remove-MgUser` on its own moves the account to deleted users, the directory recycle bin, where Microsoft keeps it with all of its properties for 30 days so that it can be restored. While it sits there, it can still block the domain. In the validated run the account was deleted from the recycle bin straight away, so that case was not tested, but the second delete settles the question:

```powershell
Remove-MgUser -UserId <OBJECT_ID>
Start-Sleep -Seconds 30
Remove-MgDirectoryDeletedItem -DirectoryObjectId <OBJECT_ID>
```

The short pause gives the directory time to register the first delete. If the second command reports that the object cannot be found, wait a little longer and run it again. To confirm the account has gone from the recycle bin as well, this should now return a not found error:

```powershell
Get-MgDirectoryDeletedItem -DirectoryObjectId <OBJECT_ID>
```

## Remove the domain and watch it leave

Recount the references, and remove the domain only when the count is zero:

```powershell
$count = (Get-MgDomainNameReference -DomainId "yourdomain.com" -All | Measure-Object).Count
"References found: $count"
if ($count -eq 0) { Remove-MgDomain -DomainId "yourdomain.com" }
```

A failed forceDelete can stay recorded in the domain state, so do not judge a later `Remove-MgDomain` by reading that state. Watch for the domain to disappear from `Get-MgDomain` instead, together with the realm lookup returning `Unknown`:

```powershell
for ($i = 1; $i -le 30; $i++) {
    Start-Sleep -Seconds 60
    $stillThere = [bool](Get-MgDomain -All | Where-Object { $_.Id -eq "yourdomain.com" })
    $realm = (Invoke-RestMethod "https://login.microsoftonline.com/getuserrealm.srf?login=test@yourdomain.com&json=1").NameSpaceType
    "{0}  Still in old tenant: {1}  Realm: {2}" -f (Get-Date -Format 'HH:mm'), $stillThere, $realm
    if (-not $stillThere -and $realm -eq "Unknown") { "Gone from the old tenant."; break }
}
```

In the validated run, the reference count was 0 after the permanent delete, `Remove-MgDomain` was accepted, and within about a minute the domain had left the holding tenant and the realm lookup returned `Unknown`. `Release-Domain.ps1 -Wait` runs the same check.

## The forceDelete API in full

forceDelete is the alternative to clearing references one by one. Know exactly what it does before you reach for it.

```powershell
$body = @{ disableUserAccounts = $false } | ConvertTo-Json

Invoke-MgGraphRequest -Method POST `
    -Uri "https://graph.microsoft.com/v1.0/domains/yourdomain.com/forceDelete" `
    -Body $body `
    -ContentType "application/json"
```

The Microsoft Graph PowerShell SDK also has a native cmdlet for the same call: `Invoke-MgForceDomainDelete -DomainId "yourdomain.com" -BodyParameter @{ disableUserAccounts = $false }`.

As part of the operation, Microsoft Entra ID:

- Updates the `userPrincipalName`, `mail` and `proxyAddresses` of every user that references the domain, so they use the initial `onmicrosoft.com` domain instead.
- Updates the `mail` of every group that references the domain, in the same way.
- Updates the `identifierUris` of every application that references the domain, in the same way.
- Deletes the domain once nothing references it.

Its purpose is renaming many objects at once. If you have dozens of users and groups on the domain and none of them need the domain any more, it saves you renaming each one by hand. With a single blocking object, the routes above are simpler and you see each change as it happens.

Points to be aware of before you run it:

- **Accepted is not done.** forceDelete runs as an asynchronous background operation, and Microsoft notes that it can take up to 24 hours to complete. A call that returns without an error tells you only that the request was accepted. In the validated run it was accepted at 19:54, and the failure was first seen when the domain state was read at 19:59. The checks before that looked only at the tenant list and the realm lookup, and showed nothing wrong.
- **Test the status with `-like 'Failed*'`.** Microsoft Learn lists `Scheduled`, `InProgress` and `Failed` as the status values. In the validated run the reason was appended inside the status string itself, so a test with `-eq 'Failed'` would have missed it.
- **disableUserAccounts defaults to true.** If you leave it out, or set it to `true`, every user it renames is also disabled and can no longer sign in. Set it to `false`, as above, if those accounts need to keep working. Microsoft notes that forceDelete from the Microsoft Entra admin center disables the accounts it renames, and that the Graph call makes this optional.
- **Exchange references must be cleared first.** Microsoft states that any references where Exchange is the provisioning service, including mail-enabled security groups and distribution lists, must be updated or removed before forceDelete. The failure in the validated run did not mention Exchange, but our reading is that this precondition is what it hit.
- **Federated domains.** Microsoft notes that forceDelete does not work if the domain uses federated authentication. In that case, users and groups on the domain have to be renamed or removed in on-premises Active Directory first.
- **There are limits.** It returns an error if more than 1,000 objects would need renaming, or if any application to be renamed is a multitenant application. It also does not succeed for a domain bought through a Microsoft 365 domain subscription, or when run by a partner on behalf of another organisation.
- **A failed attempt can linger.** A failed forceDelete can stay recorded in the domain state. After you clear the blocker and run `Remove-MgDomain`, watch for the domain to leave the tenant list, as shown above, rather than reading the state.

To read the state while forceDelete runs:

```powershell
$state = (Get-MgDomain -DomainId "yourdomain.com").State
$state | Select-Object Operation, Status, LastActionDateTime | Format-List
if ($state.Status -like 'Failed*') { Write-Warning $state.Status }
```

Once a deletion completes, `Get-MgDomain` for the domain returns a not found error.

## Confirm the release

However you got here, confirm from the outside that the domain is free before you move on:

```powershell
.\scripts\Get-DomainTenant.ps1 -Domain yourdomain.com
```

Expect `NameSpaceType` of `Unknown` and no tenant ID. In the validated run this took about a minute after the removal, but allow a few minutes. Then continue with [05-verify-new-tenant.md](05-verify-new-tenant.md).

## Safety notes

- Run forceDelete and permanent user deletion only against a tenant you administer, and only after the reference list has shown you exactly what will be renamed or removed.
- Connect with `-ContextScope Process` and check `Get-MgContext` before every destructive step. The wrong tenant is the most expensive mistake available here.
- Permanent deletion cannot be undone once the object leaves the recycle bin. Confirm the account carries nothing you need, such as mail, files or licences, before deleting it.
- Releasing the domain does not delete the holding tenant, and leaves its initial `onmicrosoft.com` domain in place.
