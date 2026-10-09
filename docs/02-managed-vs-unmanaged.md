# Managed or Unmanaged

Once you know another tenant holds the domain, the next question is what kind of tenant it is. The answer decides whether you can pull the domain across from your own tenant, or whether it has to be released from inside the holding tenant.

## Unmanaged tenants

An unmanaged tenant, often called a viral or self-service tenant, is created automatically when someone signs up for a Microsoft cloud service, for example a self-service trial, using an email address on the domain, and no tenant already holds that domain. Microsoft creates a directory to hold the account, but no global administrator is ever appointed. Nobody manages it, which is where the name comes from.

Because nobody administers it, Microsoft lets the owner of the domain take it over. External admin takeover moves the domain out of the unmanaged tenant and into yours. You add the domain to your tenant, publish the verification TXT record in DNS, and then verify with `forceTakeover` set to `true`:

```powershell
Connect-MgGraph -TenantId <DESTINATION_TENANT_ID> -Scopes "Domain.ReadWrite.All" -ContextScope Process

$body = @{ forceTakeover = $true } | ConvertTo-Json

Invoke-MgGraphRequest -Method POST `
    -Uri "https://graph.microsoft.com/v1.0/domains/yourdomain.com/verify" `
    -Body $body `
    -ContentType "application/json"
```

`Confirm-MgDomain` does not expose the `forceTakeover` parameter, which is why the call goes through `Invoke-MgGraphRequest`. Microsoft documents the full procedure under taking over an unmanaged directory as administrator in Microsoft Entra ID. After a successful external takeover, the unmanaged tenant is deleted automatically 10 days later.

## Managed tenants

A managed tenant has a real global administrator. Somebody created it deliberately and signed in as its administrator, for example a trial, a lab, an old Microsoft 365 subscription, or a tenant set up years ago by a previous IT provider. External admin takeover is for unmanaged directories, so it does not move a domain out of a tenant that has an administrator.

## How to tell which one you have

The realm lookup from [01-home-realm-discovery.md](01-home-realm-discovery.md) does not answer this. `NameSpaceType` of `Managed` describes how sign-in is handled for the domain, not whether the tenant has an administrator. Two other signals do, and both appeared in the validated run.

### A masked administrator appears

When the domain was added in the destination tenant, the admin center reported that the domain was already in use by another organisation, and showed the administrator account for that tenant with most of its characters hidden. An unmanaged tenant has no administrator to show. If you see one, the tenant is managed.

The masked address is also worth reading closely. Even partly hidden, the pattern may be enough for you to recognise an account you created yourself.

### External takeover returns an error

If you run the `forceTakeover` verification above and it returns an error instead of moving the domain, the tenant is managed. Against an unmanaged tenant the same call is expected to succeed, with the domain showing as verified in your tenant.

Make sure the verification TXT record is in place and visible in public DNS before you treat this as a signal. If the record is missing, the call fails for that reason alone, and the failure tells you nothing about the tenant type.

In the validated run, the call was made from the destination tenant with the expected TXT record live in DNS. It returned HTTP 400 with the code `Request_BadRequest` and the message:

```
Invalid cross-cloud verification code
```

Both tenants were in the same worldwide commercial cloud, so the wording is misleading. Microsoft does not document this error, and it was seen against a managed tenant. This repository treats it as one more sign of a managed tenant, not as evidence of a cloud mismatch.

## What this means for you

If the tenant is unmanaged, external admin takeover is your route and the rest of this repository is not needed.

If the tenant is managed, the domain has to be released from inside it by one of its administrators. If you have, or can recover, administrator access to it, the rest of this repository covers exactly that, starting with [03-inspect-references.md](03-inspect-references.md). If you have no way into it and do not know who does, a support case with Microsoft is the remaining route, and you can now open it with the holding tenant GUID in hand.
