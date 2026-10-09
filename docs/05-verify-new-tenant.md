# Verify in the Destination Tenant

With the domain released from the holding tenant, the last step is to verify it in the tenant where you actually want it. If you placed the verification record in DNS on an earlier attempt, this takes a few minutes at most.

## Confirm the domain is free

Start with the same public lookup you used to find the holding tenant:

```powershell
.\scripts\Get-DomainTenant.ps1 -Domain yourdomain.com
```

```
Domain          : yourdomain.com
NameSpaceType   : Unknown
FederationBrand :
AuthURL         :
TenantId        :
CloudInstance   :
RegionScope     :

No tenant claims this domain. It is free to verify.
```

`NameSpaceType` of `Unknown` and an empty tenant ID mean no tenant holds the domain. If `NameSpaceType` is `Unknown` but a tenant ID is shown, the domain is not free: see [When the realm lookup returns Unknown](01-home-realm-discovery.md#when-the-realm-lookup-returns-unknown).

The realm lookup can lag the removal, so recheck it before you verify. In the validated run it changed within about a minute, but allow a few minutes. If it still returns `Managed` with the holding tenant GUID, wait and run it again. Do not try to verify until it reads `Unknown`, because until then the verification fails exactly as it did at the start.

## Connect to the destination tenant

```powershell
Disconnect-MgGraph
Connect-MgGraph -TenantId <DESTINATION_TENANT_ID> -Scopes "Domain.ReadWrite.All" -ContextScope Process
Get-MgContext | Select-Object TenantId, Account | Format-List
```

After working in the holding tenant, it is easy to still be connected to it. Confirm that `TenantId` now shows the destination tenant GUID before you go further.

## Make sure the domain is added

If you tried to add the domain earlier, it is most likely already in the destination tenant, listed as unverified:

```powershell
Get-MgDomain -DomainId "yourdomain.com" | Select-Object Id, IsVerified | Format-Table -AutoSize
```

If it is not there, add it and read the verification TXT value:

```powershell
New-MgDomain -BodyParameter @{ Id = "yourdomain.com" }

(Get-MgDomainVerificationDnsRecord -DomainId "yourdomain.com" |
    Where-Object { $_.RecordType -eq "Txt" }).AdditionalProperties.text
```

## The TXT record may already be in place

This is the point that saves the most time. The verification TXT value, in the form `MS=ms` followed by a number, is issued for your tenant and this domain. If you added it to DNS during your first attempt, when verification failed because the holding tenant still had the domain, the record is still there and still valid. Nothing needs to change in DNS now, and verification completes as soon as the domain is free.

To check what is published, and compare it with the value from `Get-MgDomainVerificationDnsRecord`:

```powershell
Resolve-DnsName -Name yourdomain.com -Type TXT | Select-Object -ExpandProperty Strings
```

You may also see an older `MS=` value that the holding tenant used. It does no harm alongside yours, since a domain can carry several TXT records, and you can remove it later at your own pace.

If your value is not published, add it at your DNS host, wait for it to appear in the lookup above, and then continue.

## Verify the domain

```powershell
Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/domains/yourdomain.com/verify"
```

On success the call returns the domain object. In the validated run it came back about four minutes after the removal, with `isVerified` of `True` and an empty `supportedServices`. The empty list is expected: verifying a domain through Microsoft Graph proves ownership, and does not configure the domain for any service. Check the result:

```powershell
Get-MgDomain -DomainId "yourdomain.com" | Select-Object Id, IsVerified, IsDefault | Format-Table -AutoSize
```

```
Id             IsVerified IsDefault
--             ---------- ---------
yourdomain.com       True     False
```

`IsVerified` of `True` means the domain now belongs to your tenant. A sanitised capture of the full sequence is in [../logs/after-success.log](../logs/after-success.log).

## Existing mail keeps flowing

Nothing in this flow touches MX, SPF, Autodiscover or any other DNS record. Verification proves that you own the domain. It does not move mail anywhere. Inbound mail keeps going wherever the MX record points today, and outbound mail is unaffected, until you choose to move it.

That holds when the domain's mail is hosted somewhere other than the holding tenant, which is the usual situation with a dormant tenant. If the holding tenant's Exchange Online was still receiving live mail for the domain, that delivery stops when the domain is removed from it, so move that mail before you release the domain.

When you are ready to move mail to the destination tenant, add the service records the Microsoft 365 admin center asks for at that point.
