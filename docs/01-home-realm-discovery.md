# Home Realm Discovery

Before you raise a support case or change anything, find out where the domain actually lives. Two public Microsoft endpoints answer that in seconds, with no sign-in and no module.

## The user realm lookup

You can call this endpoint with any address on the domain. The address does not need to exist: in testing, `test@` on the domain returned the result for the domain.

`getuserrealm.srf` is a public endpoint that Microsoft does not formally document, so its fields can change, and the readings here come from observed responses.

```powershell
Invoke-RestMethod "https://login.microsoftonline.com/getuserrealm.srf?login=test@yourdomain.com&json=1"
```

For a domain held by another tenant, the response looks like this:

```
State                  : 4
UserState              : 1
Login                  : test@yourdomain.com
NameSpaceType          : Managed
DomainName             : yourdomain.com
FederationBrandName    : Contoso Ltd
CloudInstanceName      : microsoftonline.com
CloudInstanceIssuerUri : urn:federation:MicrosoftOnline
```

### Reading NameSpaceType

`NameSpaceType` is the field that tells you whether the domain is claimed, and how sign-in is handled for it.

- **Managed** means a tenant has verified the domain and signs users in for it directly in Microsoft Entra ID. The domain is taken.
- **Federated** means a tenant has verified the domain and sends sign-in to an external identity provider, such as AD FS. The domain is equally taken. In responses observed for federated domains, there is also an `AuthURL` field with the address of that provider, which tells you who runs sign-in for the domain. This field is observed, not documented.
- **Unknown** means no tenant has verified the domain. It is free to verify in yours.

Note that `Managed` here describes how sign-in is handled. It does not tell you whether the tenant has an administrator, which is a separate question covered in [02-managed-vs-unmanaged.md](02-managed-vs-unmanaged.md).

### Reading FederationBrandName

`FederationBrandName` is the organisation display name of the holding tenant, the name entered when the tenant was created or later changed in its properties. It is the most useful clue you have to who owns the tenant. If you recognise it, for example an old company name, a trial you once set up, or the name of a previous IT provider, you may already know who has the credentials, and that person may be you.

### Reading CloudInstanceName

`CloudInstanceName` is the Microsoft cloud the tenant belongs to. `microsoftonline.com` is the worldwide commercial cloud. National clouds such as US Government use separate sign-in endpoints, for example `login.microsoftonline.us`, so a tenant there reports a different cloud instance.

## The OpenID configuration

Every Microsoft Entra tenant publishes an OpenID Connect discovery document, and you can request it by domain name rather than by tenant ID. The document identifies the tenant behind the domain.

```powershell
$cfg = Invoke-RestMethod "https://login.microsoftonline.com/yourdomain.com/v2.0/.well-known/openid-configuration"
$cfg.issuer
$cfg.cloud_instance_name
$cfg.tenant_region_scope
```

```
https://login.microsoftonline.com/11111111-1111-1111-1111-111111111111/v2.0
microsoftonline.com
NA
```

### The tenant GUID in the issuer

The `issuer` is a URL with the tenant GUID between the host name and `/v2.0`. That GUID is the holding tenant ID. To pull it out on its own:

```powershell
($cfg.issuer -split '/')[3]
```

Keep a note of it. You need it to connect to the holding tenant in [03-inspect-references.md](03-inspect-references.md).

If no tenant holds the domain, this request returned an error in testing, saying the tenant could not be found. That is observed behaviour, not documented behaviour, and it agrees with a `NameSpaceType` of `Unknown`.

### cloud_instance_name and tenant_region_scope

`cloud_instance_name` is the same information as `CloudInstanceName` in the realm lookup: the cloud the tenant lives in, `microsoftonline.com` for the worldwide commercial cloud.

`tenant_region_scope` is a short region code for the tenant, such as `NA`, `EU` or `AS`. Microsoft Learn does not describe its values in detail, so treat it as a hint about where the tenant was set up rather than as a fact you rely on.

## Compare against your own tenant

Run both lookups twice: once against the stuck domain, and once against a domain you know is in your own tenant. Your own initial domain, `destinationtenant.onmicrosoft.com`, works for this.

- If the tenant GUIDs are the same, the domain is already in your own directory, and the problem is something other than another tenant holding it.
- If the GUIDs differ, the domain sits in a separate directory, and the GUID from the stuck domain is the holding tenant.

A different region scope on its own does not mean a different cloud. One tenant can report `NA` and the other `AS`, and both can report `microsoftonline.com` as the cloud instance. They are in the same worldwide commercial cloud. The GUID is what tells you the directories are separate. The cloud instance is what would tell you they are in different clouds.

## Doing it in one step

[../scripts/Get-DomainTenant.ps1](../scripts/Get-DomainTenant.ps1) runs both lookups, extracts the tenant GUID from the issuer, and prints the result as one object, followed by one line that interprets it:

- **Managed:** the domain is claimed by a tenant that signs users in itself.
- **Federated:** the domain is claimed by a tenant that sends sign-in to an external identity provider, followed by the federation brand and the `AuthURL` when the response includes them.
- **Unknown:** no tenant claims the domain, and it is free to verify.
- **Anything else**, including a failed lookup: the result is inconclusive, and you should run the lookup again before acting on it.

Add `-CompareDomain` with a domain from your own tenant and it also tells you whether the two domains sit in the same tenant.

```powershell
.\scripts\Get-DomainTenant.ps1 -Domain yourdomain.com
.\scripts\Get-DomainTenant.ps1 -Domain yourdomain.com -CompareDomain destinationtenant.onmicrosoft.com
```

A sanitised capture of these lookups for a held domain, including the comparison, is in [../logs/before-discovery.log](../logs/before-discovery.log).
