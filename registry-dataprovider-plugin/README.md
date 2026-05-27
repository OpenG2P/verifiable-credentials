# registry-dataprovider-plugin

An Inji Certify **`DataProviderPlugin`** that fetches a citizen's VC claims from an **external
OpenG2P Registry database** using **configurable, scope-based SQL queries** and a **configurable
token-claim → query-parameter** binding.

It improves on the stock `PostgresDataProviderPlugin` in two ways:
- it connects to a **dedicated external datasource** (the Registry DB) instead of Certify's own DB
  (no FDW / replication / cross-schema gymnastics);
- the lookup identifier is **configurable** (`param-claim-mapping`) instead of hardcoded to `sub`,
  so a phone-number login binds cleanly from the `phone_number` claim.

The table/view, joins and filters all live in the **SQL config**, so the plugin is
schema-agnostic — you never recompile it to change what is read.

## Build (no local Java/Maven required)

The build runs inside the Maven Docker image:

```bash
./build.sh
# -> target/registry-dataprovider-plugin.jar
```

Or via Docker build:
```bash
docker build --target artifact --output type=local,dest=./dist .
# -> dist/registry-dataprovider-plugin.jar
```

(If you do have JDK 21 + Maven locally, `mvn -DskipTests package` works too.)

All dependencies are `provided` (present on Certify's runtime classpath), so the JAR contains
only this plugin's classes — avoiding library version clashes.

## Deploy into Inji Certify

1. **Place the JAR** in Certify's plugin loader path (e.g. mount it at
   `/home/mosip/additional_jars/` and enable that volume in the certify compose/Helm).
2. **Add the properties** from [`config/certify-registry.properties.sample`](config/certify-registry.properties.sample)
   to your active Certify profile (selection, datasource, `scope-query-mapping`,
   `param-claim-mapping`, issuer DID, and the OIDC token-validation settings).
3. **Create the read-only view** in the Registry DB — see
   [`config/beneficiary_vc_view.sample.sql`](config/beneficiary_vc_view.sample.sql) — and grant a
   least-privilege `certify_ro` user `SELECT` on it.
4. **Define the credential type** in Certify (`credential_config`: template, issuer DID, signing
   key, scope = the key used in `scope-query-mapping`).

## How it works

At issuance Certify calls `fetchData(identityDetails)` (the validated token claims). The plugin:
1. reads the `scope` claim, picks the matching SQL from `scope-query-mapping`;
2. binds each SQL named parameter from the claim named in `param-claim-mapping`
   (default intent: `:id` ← `phone_number`);
3. queries the Registry datasource;
4. returns the single matching row's columns as the VC claims.

**Behaviour:** exactly one active row → claims returned; **no row** (absent **or** inactive —
filtered in the view) → `DataProviderExchangeException` → Certify returns an error → the portal
shows "no eligible record". Multiple rows → first row used + a warning logged (enforce 1:1 / add
`LIMIT 1`).

## Configuration reference

| Property | Purpose |
|---|---|
| `mosip.certify.integration.scan-base-package` | must include `org.openg2p.certify.registry` |
| `mosip.certify.integration.data-provider-plugin` | `RegistryDataProviderPlugin` (activates this plugin) |
| `mosip.certify.data-provider-plugin.registrydb.url` / `.username` / `.password` / `.driver-class-name` | external Registry datasource |
| `mosip.certify.data-provider-plugin.scope-query-mapping` | `{ '<scope>':'<SQL with :params>' }` |
| `mosip.certify.data-provider-plugin.param-claim-mapping` | `{ '<sqlParam>':'<tokenClaim>' }`, e.g. `{ 'id':'phone_number' }` |

## Notes & hardening

- **Identifier:** binding `:id` ← `phone_number` assumes the access token carries `phone_number`
  and the Registry is 1:1 on phone. Any claim can be used; multiple params are supported.
- **Security:** use a **read-only** DB user limited to the **view**; reach the DB over TLS;
  restrict network access to Certify only.
- **Column → claim names:** alias view columns to match the credential template `${...}` vars.
- **Dates/types:** format dates as text in the view for clean string claims.
- The default datasource uses Spring Boot's `DataSourceBuilder` (HikariCP on Certify's
  classpath). Tune pool size/timeouts via standard properties if needed.
