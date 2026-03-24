# Implementation Plan: Add Apache Polaris alongside Trino

## Overview

Add Apache Polaris (Iceberg REST Catalog) to the Kubernetes cluster alongside the existing Trino deployment. Polaris will replace Trino's current JDBC-based Iceberg catalog with a centralized REST catalog, enabling multi-engine access (Trino, Spark, Flink) through a standard API. Polaris will use external OIDC authentication via Zitadel (`auth.gsingh.io`), persist metadata in the existing external PostgreSQL (`192.168.2.119`), and be deployed to the `data-platform` namespace with an ingress at `polaris.gsingh.io`.

## Global Context

### Current Architecture
- **Pattern**: ArgoCD App-of-Apps. `charts/root-app/` contains ArgoCD Application CRDs that point to external Helm repos.
- **Version pinning**: All chart versions are pinned in `charts/root-app/values.yaml` via `<app>.version`.
- **Trino**: Deployed in `data-platform` namespace, version `1.42.0`, with a JDBC-based Iceberg catalog connecting directly to PostgreSQL + S3 (`s3v2.gsingh.io`).
- **Trino Iceberg catalog**: Uses `iceberg.catalog.type=jdbc` with PostgreSQL for metadata and S3 for data storage at `s3a://datastore/iceberg`.
- **Zitadel**: Running at `auth.gsingh.io` (chart v9.17.1), used as OIDC provider by multiple apps (Coder, Fission, Dagster/OAuth2Proxy, ArgoWF).
- **External PostgreSQL**: `192.168.2.119` used by Airflow, Dagster, OpenProject, Langfuse, Windmill, and Prefect.
- **Secrets pattern**: All apps use `existingSecret` references to pre-created Kubernetes secrets.
- **Testing**: `helm lint charts/root-app/` and `just test-render <app>` for validation.

### Apache Polaris Key Facts
- **Official Helm chart**: `https://downloads.apache.org/polaris/helm-chart` (chart name: `polaris`)
- **Docker image**: `apache/polaris` on Docker Hub
- **Latest release**: `1.3.0-incubating` (note: Helm treats `-incubating` as pre-release, may need `--devel` flag or use the chart version directly via ArgoCD)
- **Ports**: 8181 (REST API), 8182 (management/health/metrics)
- **Persistence**: Supports `in-memory`, `relational-jdbc` (PostgreSQL), `nosql` (MongoDB)
- **Authentication**: `internal`, `external` (OIDC), or `mixed`
- **External OIDC**: Validates JWT bearer tokens from an external IdP via JWKS discovery. Built on Quarkus OIDC.

### Trino-Polaris Integration
When switching from JDBC to Polaris REST catalog, Trino's catalog config changes from:
```properties
# BEFORE (JDBC)
connector.name=iceberg
iceberg.catalog.type=jdbc
iceberg.jdbc-catalog.connection-url=jdbc:postgresql://...
```
to:
```properties
# AFTER (REST via Polaris)
connector.name=iceberg
iceberg.catalog.type=rest
iceberg.rest-catalog.uri=http://polaris.data-platform.svc.cluster.local:8181/api/catalog
iceberg.rest-catalog.security=OAUTH2
iceberg.rest-catalog.oauth2.credential=<client_id>:<client_secret>
iceberg.rest-catalog.oauth2.server-uri=https://auth.gsingh.io/oauth/v2/token
```

## Architecture Decisions

1. **Replace JDBC catalog with Polaris REST catalog**: Trino's existing `iceberg` catalog will switch from `jdbc` to `rest` type, pointing to Polaris. This provides centralized catalog management and multi-engine support.

2. **External OIDC via Zitadel**: Polaris will use `authentication.type: external` with Zitadel as the OIDC provider. Trino will authenticate to Polaris using OAuth2 client credentials flow against Zitadel's token endpoint.

3. **Same namespace as Trino**: Both Polaris and Trino will live in `data-platform` for simpler networking. Trino connects to Polaris via `polaris.data-platform.svc.cluster.local:8181`.

4. **External PostgreSQL for Polaris metadata**: Reuse the existing PostgreSQL server at `192.168.2.119` with a new `polaris` database, consistent with the pattern used by other apps.

5. **Ingress enabled**: Polaris will be accessible at `polaris.gsingh.io` for external tools (Spark, Flink, etc.) to access the REST catalog.

6. **Phased approach**: Deploy Polaris first, configure and verify it, then modify Trino to use it. This avoids breaking the existing Trino setup during Polaris deployment.

## Phase Versioning Strategy

### Git Feature Branch

Each top-level phase executes on its own feature branch:

**Branch naming convention**: `feature/[phase-number]-[kebab-case-name]`
- Example: `feature/1-deploy-polaris`, `feature/2-configure-zitadel-oidc`

**Benefits**:
- Clean isolation between phases
- Easy to review and merge completed phases via PRs
- Clear commit history per phase

**For phases with dependencies**: After completing a phase, merge its branch into main before starting dependent phases.

## Assumptions

1. The external PostgreSQL at `192.168.2.119` is accessible from the `data-platform` namespace and can host a new `polaris` database.
2. Zitadel at `auth.gsingh.io` supports creating new OIDC applications (service users) for Polaris and Trino.
3. The S3 endpoint at `s3v2.gsingh.io` and bucket `datastore` will remain the same for Iceberg data storage.
4. ArgoCD auto-sync is enabled, so changes to `values.yaml` will trigger automatic rollout.
5. The Polaris Helm chart version `1.3.0-incubating` is compatible with ArgoCD's chart fetching (ArgoCD handles pre-release semver differently than Helm CLI).
6. Zitadel's role claim format (`urn:zitadel:iam:org:project:roles`) can be mapped to Polaris principal roles, or a Zitadel Action can be configured to emit roles in a simpler format.

---

## Phases

### Phase 1: Create Polaris Database and Kubernetes Secrets ✅ COMPLETED

**Objective**: Provision the PostgreSQL database for Polaris and create all required Kubernetes secrets in the `data-platform` namespace.

**Complexity**: low
**Estimated Time**: 20 min

**Prerequisites**:
- None

**Context for this Phase**:
- Polaris needs a PostgreSQL database for metadata persistence (`relational-jdbc` backend).
- The external PostgreSQL server is at `192.168.2.119`. Other apps (Airflow, Dagster, etc.) already use it.
- Use the existing `just generate-db-sql` recipe to **generate** SQL (it only prints to stdout -- you must manually run the SQL on the PostgreSQL server).
- Kubernetes secrets are documented as sample YAML manifests in the `samples/` directory, following the existing convention (see `samples/dagster-postgresql-secret.yaml`, `samples/prefect-db-secret.yaml`, `samples/oauth2-proxy-secret-example.yaml` for reference).
- Sample files contain placeholder values (`PASSWORD_HERE`, `YOUR_CLIENT_ID_HERE`, etc.) and comments with `kubectl create` commands. **Actual secrets are never committed** -- the user creates them manually via `kubectl apply` or `kubectl create`.
- Polaris requires these secrets in the `data-platform` namespace:
  1. **`polaris-db-credentials`**: PostgreSQL connection details (keys: `username`, `password`, `jdbcUrl`)
  2. **`polaris-oidc-client`**: Zitadel OIDC client ID and secret (keys: `clientId`, `clientSecret`) -- placeholder for now, actual values created in Phase 2
  3. **`trino-polaris-oauth`**: Trino's OAuth2 client credential for authenticating to Polaris via Zitadel (key: `POLARIS_OAUTH_CREDENTIAL`) -- placeholder for now, actual value created in Phase 2
- The `data-platform` namespace already exists (Trino is deployed there).

**Files**:
| File | Action | Purpose |
|------|--------|---------|
| `samples/polaris-db-credentials.yaml` | create | Sample secret manifest for Polaris PostgreSQL connection |
| `samples/polaris-oidc-client.yaml` | create | Sample secret manifest for Polaris Zitadel OIDC client |
| `samples/trino-polaris-oauth.yaml` | create | Sample secret manifest for Trino's OAuth2 credential to Polaris |

**Implementation Steps**:
1. **Generate PostgreSQL setup SQL** by running `just generate-db-sql polaris polaris`. This prints SQL and a random password to the terminal. **Manually connect** to the PostgreSQL server at `192.168.2.119` (e.g., `psql -h 192.168.2.119 -U postgres`) and execute the generated SQL statements.

2. **Create `samples/polaris-db-credentials.yaml`** following the pattern of `samples/dagster-postgresql-secret.yaml`:
   - Include header comments explaining:
     - Prerequisites (database must exist on `192.168.2.119`)
     - `kubectl create` command alternative
     - How to test the connection
   - Secret keys: `username`, `password`, `jdbcUrl`
   - Example structure:
     ```yaml
     apiVersion: v1
     kind: Secret
     metadata:
       name: polaris-db-credentials
       namespace: data-platform
       labels:
         app.kubernetes.io/name: polaris
         app.kubernetes.io/instance: polaris
     type: Opaque
     stringData:
       username: polaris
       password: PASSWORD_HERE
       jdbcUrl: "jdbc:postgresql://192.168.2.119:5432/polaris"
     ```

3. **Create `samples/polaris-oidc-client.yaml`** following the pattern of `samples/oauth2-proxy-secret-example.yaml`:
   - Include header comments explaining this is for Polaris's Zitadel OIDC integration
   - Note that actual values come from Phase 2 (Zitadel configuration)
   - Secret keys: `clientId`, `clientSecret`
   - Example structure:
     ```yaml
     apiVersion: v1
     kind: Secret
     metadata:
       name: polaris-oidc-client
       namespace: data-platform
     type: Opaque
     stringData:
       clientId: "YOUR_POLARIS_CLIENT_ID_HERE"
       clientSecret: "YOUR_POLARIS_CLIENT_SECRET_HERE"
     ```

4. **Create `samples/trino-polaris-oauth.yaml`**:
   - Include header comments explaining this is for Trino's OAuth2 client credentials to authenticate to Polaris via Zitadel
   - Note the format is `client_id:client_secret`
   - Note that actual values come from Phase 2 (Zitadel service user creation)
   - Secret key: `POLARIS_OAUTH_CREDENTIAL`
   - Example structure:
     ```yaml
     apiVersion: v1
     kind: Secret
     metadata:
       name: trino-polaris-oauth
       namespace: data-platform
     type: Opaque
     stringData:
       POLARIS_OAUTH_CREDENTIAL: "YOUR_TRINO_CLIENT_ID:YOUR_TRINO_CLIENT_SECRET"
     ```

5. **Create the database secret** in the cluster using the password from step 1:
   ```bash
   kubectl apply -f samples/polaris-db-credentials.yaml  # after replacing PASSWORD_HERE
   # Or equivalently:
   kubectl create secret generic polaris-db-credentials \
     --from-literal=username=polaris \
     --from-literal=password='<password-from-step-1>' \
     --from-literal=jdbcUrl='jdbc:postgresql://192.168.2.119:5432/polaris' \
     --namespace data-platform
   ```

6. **Verify** secrets and database:
   ```bash
   kubectl get secrets -n data-platform | grep polaris
   ```

**Verification**:
- [x] PostgreSQL database `polaris` exists on `192.168.2.119` with user `polaris` *(manual step)*
- [x] `samples/polaris-db-credentials.yaml` exists with correct structure and placeholder values
- [x] `samples/polaris-oidc-client.yaml` exists with correct structure and placeholder values
- [x] `samples/trino-polaris-oauth.yaml` exists with correct structure and placeholder values
- [x] Secret `polaris-db-credentials` exists in `data-platform` namespace with keys `username`, `password`, `jdbcUrl` *(manual step)*
- [x] Sample files follow the conventions of existing samples (comments, labels, `stringData`)

**Completion Gate**:
> This phase is NOT complete until the user has reviewed the work and explicitly confirmed it is done. Do not proceed to dependent phases or mark this phase as finished without user approval.

**Outputs**:
- PostgreSQL database `polaris` on external server
- Kubernetes secret `polaris-db-credentials` in `data-platform` namespace (applied to cluster)
- Sample YAML files in `samples/` for all three Polaris-related secrets (committed to repo)

**Git Branch Setup**:
```bash
git checkout -b feature/1-polaris-db-and-secret-samples
```

**After completing this phase**:
```bash
git add .
git commit -m "feat: add Polaris database secret samples and provision PostgreSQL database"
git push -u origin feature/1-polaris-db-and-secret-samples
git checkout main
git merge feature/1-polaris-db-and-secret-samples
git branch -d feature/1-polaris-db-and-secret-samples
```

---

### Phase 2: Configure Zitadel OIDC for Polaris and Trino ✅ COMPLETED

**Objective**: Create OIDC applications and service users in Zitadel for Polaris token validation and Trino client credentials authentication.

**Complexity**: medium
**Estimated Time**: 30 min

**Prerequisites**:
- Phase 1 completed (secrets exist in cluster)
- Access to Zitadel admin console at `https://auth.gsingh.io`

**Context for this Phase**:
- Zitadel is the OIDC provider running at `auth.gsingh.io` (chart version 9.17.1, template at `charts/root-app/templates/zitadel.yaml`).
- Polaris uses Quarkus OIDC bearer token validation. It needs:
  - A Zitadel **API Application** (or project) so Polaris can validate JWT tokens against Zitadel's JWKS endpoint.
  - The OIDC discovery URL: `https://auth.gsingh.io/.well-known/openid-configuration`
- Trino needs a **Service User** (machine account) in Zitadel with client credentials to obtain tokens for authenticating to Polaris.
- Zitadel puts roles in `urn:zitadel:iam:org:project:roles` as a JSON object. Polaris needs roles in a format it can map to `PRINCIPAL_ROLE:<name>`. A Zitadel **Action** (custom script) may be needed to flatten roles into a simple array claim.
- After creating the Zitadel application, create the `polaris-oidc-client` and `trino-polaris-oauth` secrets using the sample YAML files from Phase 1 (`samples/polaris-oidc-client.yaml` and `samples/trino-polaris-oauth.yaml`), replacing placeholder values with the actual credentials from Zitadel.

**Files**:
| File | Action | Purpose |
|------|--------|---------|
| (no code files) | manual | Zitadel admin console configuration + secret creation from samples |

**Implementation Steps**:
1. **In Zitadel admin console** (`https://auth.gsingh.io`):
   a. Create a new **Project** called `polaris` (or add to an existing project).
   b. Create an **API Application** named `polaris-server` within the project:
      - Auth method: `BASIC` (client_id + client_secret)
      - Note the generated `client_id` and `client_secret`
   c. Create a **Service User** (machine user) named `trino-polaris-client`:
      - Auth method: Client credentials (JWT or client secret)
      - Note the generated `client_id` and `client_secret`
      - Assign this user the project role(s) that Polaris will recognize (e.g., `catalog_admin`, `service_admin`)
    d. **Record the `polaris` project's numeric ID** from the Zitadel console URL when viewing the project (e.g. `364792263672399345`). This ID is required in Phase 4 and Phase 5 to construct the token scope:
       ```
       openid urn:zitadel:iam:org:projects:roles urn:zitadel:iam:org:project:id:<PROJECT_ID>:aud
       ```
       - `urn:zitadel:iam:org:projects:roles` — instructs Zitadel to include all project roles in the JWT
       - `urn:zitadel:iam:org:project:id:<PROJECT_ID>:aud` — adds the project as a token audience, which is required for Zitadel to emit the project's roles
       Without both scopes, the JWT will contain no role claims and Polaris will deny all requests.

    e. Define project roles that map to Polaris principal roles:
       - `service_admin` -- full Polaris admin access
       - `catalog_admin` -- catalog management
       - `table_read` -- read-only table access (optional, for future use)
    f. (Optional) Create a Zitadel **Action** to flatten the role claim:
      - Zitadel emits roles as `{"role_name": {"orgid": "orgname"}}` under `urn:zitadel:iam:org:project:roles`
      - If Polaris's `principalRolesMapper` regex can handle this format, no Action is needed
      - Otherwise, create an Action that emits roles as a simple array under a custom claim (e.g., `polaris_roles`)

2. **Create Kubernetes secrets** using the sample files from Phase 1:
   a. Copy `samples/polaris-oidc-client.yaml`, replace placeholders with actual values from step 1b, and apply:
      ```bash
      # Edit the sample with real values, then:
      kubectl apply -f samples/polaris-oidc-client.yaml
      # Or create directly:
      kubectl create secret generic polaris-oidc-client \
        --namespace data-platform \
        --from-literal=clientId='<polaris-server-client-id>' \
        --from-literal=clientSecret='<polaris-server-client-secret>'
      ```
   b. Copy `samples/trino-polaris-oauth.yaml`, replace placeholders with actual values from step 1c, and apply:
      ```bash
      # Edit the sample with real values, then:
      kubectl apply -f samples/trino-polaris-oauth.yaml
      # Or create directly:
      kubectl create secret generic trino-polaris-oauth \
        --namespace data-platform \
        --from-literal=POLARIS_OAUTH_CREDENTIAL='<trino-client-id>:<trino-client-secret>'
      ```

3. **Verify Zitadel OIDC discovery** is accessible:
   ```bash
   curl -s https://auth.gsingh.io/.well-known/openid-configuration | jq .jwks_uri
   ```

**Verification**:
- [x] Zitadel project `polaris` exists with API application `polaris-server`
- [x] Zitadel service user `trino-polaris-client` exists with client credentials
- [x] Project roles are defined and assigned to the service user
- [x] Secret `polaris-oidc-client` updated with actual client secret and client ID
- [x] Secret `trino-polaris-oauth` created with Trino's OAuth2 credential
- [x] OIDC discovery endpoint returns valid JWKS URI

**Completion Gate**:
> This phase is NOT complete until the user has reviewed the work and explicitly confirmed it is done. Do not proceed to dependent phases or mark this phase as finished without user approval.

**Outputs**:
- Zitadel OIDC applications configured for Polaris and Trino
- Updated `polaris-oidc-client` secret with real credentials
- New `trino-polaris-oauth` secret for Trino's client credentials
- Knowledge of the exact role claim path and format for Polaris configuration

**Git Branch Setup**:
```bash
git checkout -b feature/2-configure-zitadel-oidc
```

**After completing this phase**:
```bash
git add .
git commit -m "feat: document Zitadel OIDC configuration for Polaris and Trino"
git push -u origin feature/2-configure-zitadel-oidc
git checkout main
git merge feature/2-configure-zitadel-oidc
git branch -d feature/2-configure-zitadel-oidc
```

---

### Phase 3: Deploy Apache Polaris via ArgoCD ✅ COMPLETED

**Objective**: Add the Polaris ArgoCD Application template and values configuration to deploy Polaris into the `data-platform` namespace with PostgreSQL persistence and Zitadel OIDC authentication.

**Complexity**: high
**Estimated Time**: 45 min

**Prerequisites**:
- Phase 1 completed (database and secrets exist)
- Phase 2 completed (Zitadel OIDC configured, secrets updated)

**Context for this Phase**:
- This follows the App-of-Apps pattern used by all other applications in this repo.
- The ArgoCD Application CRD template goes in `charts/root-app/templates/polaris.yaml`.
- Values go in `charts/root-app/values.yaml` under a new `polaris:` key.
- The official Polaris Helm chart is at `https://downloads.apache.org/polaris/helm-chart`, chart name `polaris`.
- **Important**: The latest version `1.3.0-incubating` uses a pre-release semver suffix. ArgoCD may handle this differently than Helm CLI. If ArgoCD cannot resolve the version, try using the chart version without the suffix or check if the Helm repo index lists it differently.
- Polaris Helm chart key values sections:
  - `persistence.type`: `relational-jdbc`
  - `persistence.relationalJdbc.secret`: references `polaris-db-credentials`
  - `authentication.type`: `external`
  - `authentication.tokenService.type`: `disabled` (no internal token endpoint)
  - `oidc.authServeUrl`: `https://auth.gsingh.io`
  - `oidc.client.id`: Polaris client ID from Zitadel
  - `oidc.client.secret.name`: `polaris-oidc-client`
  - `oidc.principalMapper`: maps JWT `sub` and `preferred_username` claims
  - `oidc.principalRolesMapper`: maps Zitadel role claims to Polaris roles
  - `ingress.enabled`: true, host `polaris.gsingh.io`
  - `storage.secret`: references S3 credentials for Iceberg warehouse access
- Existing templates to reference for patterns:
  - `charts/root-app/templates/trino.yaml` -- external Helm chart with complex values passthrough
  - `charts/root-app/templates/dagster.yaml` -- external chart with PostgreSQL and ingress config
  - `charts/root-app/templates/langfuse.yaml` -- external chart with secrets references
- The template must be wrapped in `{{- if .Values.polaris.enabled }}` / `{{- end }}`.
- Include `resources-finalizer.argocd.argoproj.io` finalizer.
- Include `syncPolicy.automated` with `selfHeal: true`, `prune: true`, and `CreateNamespace=true`.

**Files**:
| File | Action | Purpose |
|------|--------|---------|
| `charts/root-app/templates/polaris.yaml` | create | ArgoCD Application CRD for Polaris |
| `charts/root-app/values.yaml` | modify | Add `polaris:` configuration block |

**Implementation Steps**:
1. Add the `polaris` configuration block to `charts/root-app/values.yaml` (insert after the `trino` block, around line 411, to keep data-platform apps together):
   ```yaml
   polaris:
     enabled: true
     version: "1.3.0-incubating"
     namespace: data-platform
     ingress:
       enabled: true
       host: polaris.gsingh.io
     persistence:
       type: relational-jdbc
       secret: polaris-db-credentials
     storage:
       s3:
         enabled: true
         credentialsSecret: trino-iceberg-s3  # Reuse existing S3 credentials
     oidc:
       authServerUrl: "https://auth.gsingh.io"
       clientId: "<polaris-server-client-id>"  # From Phase 2
       clientSecret:
         name: polaris-oidc-client
         key: clientSecret
       principalMapper:
         idClaim: "sub"
         nameClaim: "preferred_username"
       rolesClaimPath: "urn:zitadel:iam:org:project:roles"
     features:
       supportedStorageTypes:
         - S3
   ```

2. Create `charts/root-app/templates/polaris.yaml` following the ArgoCD Application CRD pattern:
   - Use `{{- if .Values.polaris.enabled }}` guard
   - Source: `repoURL: https://downloads.apache.org/polaris/helm-chart`, `chart: polaris`, `targetRevision: {{ .Values.polaris.version }}`
   - Pass helm values for:
     - `persistence` (type + JDBC secret reference)
     - `authentication` (type: external, tokenService disabled)
     - `oidc` (authServeUrl, client, principalMapper, principalRolesMapper)
     - `ingress` (enabled, host)
     - `storage` (S3 credentials secret)
     - `features` (SUPPORTED_CATALOG_STORAGE_TYPES)
   - Destination: `namespace: {{ .Values.polaris.namespace | default "data-platform" }}`
   - SyncPolicy: automated, selfHeal, prune, CreateNamespace

3. Run `helm lint charts/root-app/` to validate the chart.

4. Run `just test-render polaris` to verify the template renders correctly.

5. Inspect the rendered output to verify:
   - Correct Helm repo URL and chart version
   - PostgreSQL secret reference is correct
   - OIDC configuration matches Zitadel setup from Phase 2
   - Ingress host is `polaris.gsingh.io`
   - S3 storage credentials are referenced

6. If ArgoCD has issues resolving `1.3.0-incubating` as a chart version, investigate alternatives:
   - Use the Git source approach instead: `repoURL: https://github.com/apache/polaris.git`, `path: helm/polaris`, `targetRevision: apache-polaris-1.3.0-incubating` (git tag)
   - Or check the Helm repo index for the exact version string

**Verification**:
- [x] `helm lint charts/root-app/` passes with no errors
- [x] `just test-render polaris` renders a valid ArgoCD Application CRD
- [x] Rendered YAML contains correct `repoURL`, `chart`, and `targetRevision`
- [x] Rendered YAML contains PostgreSQL persistence configuration
- [x] Rendered YAML contains external OIDC authentication configuration
- [x] Rendered YAML contains ingress with host `polaris.gsingh.io`
- [x] Rendered YAML contains S3 storage configuration
- [x] After ArgoCD sync: Polaris pods are running in `data-platform` namespace
- [x] Polaris health endpoint responds: `curl http://polaris.data-platform.svc.cluster.local:8182/q/health`
- [x] Polaris REST API responds: `curl https://polaris.gsingh.io/api/catalog/v1/config`

**Completion Gate**:
> This phase is NOT complete until the user has reviewed the work and explicitly confirmed it is done. Do not proceed to dependent phases or mark this phase as finished without user approval.

**Outputs**:
- `charts/root-app/templates/polaris.yaml` -- ArgoCD Application CRD
- Updated `charts/root-app/values.yaml` with `polaris:` configuration
- Running Polaris instance in `data-platform` namespace

**Git Branch Setup**:
```bash
git checkout -b feature/3-deploy-polaris
```

**After completing this phase**:
```bash
git add .
git commit -m "feat: add Apache Polaris ArgoCD application with OIDC and PostgreSQL persistence"
git push -u origin feature/3-deploy-polaris
git checkout main
git merge feature/3-deploy-polaris
git branch -d feature/3-deploy-polaris
```

---

### Phase 4: Bootstrap Polaris Principals, Initialize Catalog, and Verify ✅ COMPLETED

**Objective**: Use a temporary mixed-auth bootstrap path to seed Polaris principals/roles, initialize the catalog and namespace, then verify external OIDC works end-to-end.

**Complexity**: high
**Estimated Time**: 45 min

**Prerequisites**:
- Phase 3 completed (Polaris is running and accessible)

**Context for this Phase**:
- External OIDC-only mode can validate a Zitadel token but still fail with `Unable to fetch principal entity` if the mapped principal is not yet present in Polaris metastore.
- Polaris management operations require principals and principal roles to already exist, which creates a bootstrap dependency when starting from a clean metastore.
- Resolve this by temporarily using `authentication.type: mixed` so internal bootstrap credentials can seed entities, while keeping OIDC config in place.
- In mixed mode, `authentication.tokenService.type` must be enabled (`default`), and token broker keys should come from a stable secret (`polaris-token-keys`).
- After seeding, either:
  1. Keep `mixed` as break-glass admin access, or
  2. Revert to strict `external` + `tokenService.type: disabled`.
- The Polaris REST API base URL: `https://polaris.gsingh.io/api` (or internal: `http://polaris.data-platform.svc.cluster.local:8181/api`).

**Files**:
| File | Action | Purpose |
|------|--------|---------|
| `scripts/init-polaris-catalog.sh` | create | Idempotent bootstrap/init script for principals, roles, catalog, and namespace |

**Implementation Steps**:
1. Temporarily switch Polaris auth mode to bootstrap-friendly mixed mode:
   a. Create token broker key secret in `data-platform` (if it does not already exist):
      ```bash
      openssl genrsa -out private.pem 2048
      openssl rsa -in private.pem -pubout -out public.pem
      kubectl create secret generic polaris-token-keys \
        --namespace data-platform \
        --from-file=private.pem \
        --from-file=public.pem
      ```
   b. Update Polaris runtime auth config (via temporary ArgoCD override or temporary values edit):
      ```yaml
      authentication:
        type: mixed
        tokenService:
          type: default
        tokenBroker:
          type: rsa-key-pair
          secret:
            name: polaris-token-keys
            rsaKeyPair:
              publicKey: public.pem
              privateKey: private.pem
      ```
   c. Sync ArgoCD and wait for Polaris rollout to complete before running bootstrap calls.

2. Create bootstrap admin credentials for internal auth (one-time for empty metastore):
   a. Run Polaris admin tool bootstrap job in-cluster (example command from Polaris docs):
      ```bash
      kubectl run polaris-bootstrap \
        -n data-platform \
        --image=apache/polaris-admin-tool:latest \
        --restart=Never \
        --rm -it \
        --env="polaris.persistence.type=relational-jdbc" \
        --env="quarkus.datasource.username=<db-user>" \
        --env="quarkus.datasource.password=<db-password>" \
        --env="quarkus.datasource.jdbc.url=<jdbc-url>" \
        -- \
        bootstrap -r POLARIS -c POLARIS,root,<bootstrap-password>
      ```
   b. Store bootstrap credentials securely (do not commit).

3. Create `scripts/init-polaris-catalog.sh` that is idempotent and supports both bootstrap and validation tokens:
   a. Obtain an internal Polaris token (bootstrap path) using the bootstrapped `root` principal.
   b. Create or verify a principal matching the Zitadel service subject (`sub`) claim used by Polaris `oidc.principalMapper.idClaimPath`.
   c. Create or verify required principal roles (for example `service_admin`, `catalog_admin`).
   d. Assign principal roles to the target principal.
   e. Create or verify catalog `iceberg` with S3 storage settings.
   f. Create or verify catalog roles and grants.
   g. Create or verify initial namespace (for example `default`).

4. Make the script configurable with environment variables or flags:
   - Polaris URL (default: `https://polaris.gsingh.io`)
   - Bootstrap principal and password
   - Zitadel token endpoint and client credentials (for post-bootstrap validation)
   - Zitadel project ID and scopes
   - Catalog name (default: `iceberg`) and S3 warehouse location

5. Verify external OIDC path after seeding:
   a. Obtain a Zitadel token using Trino service user credentials:
      ```bash
      ZITADEL_TOKEN=$(curl -s -X POST https://auth.gsingh.io/oauth/v2/token \
        -d "grant_type=client_credentials" \
        -d "client_id=<trino-client-id>" \
        -d "client_secret=<trino-client-secret>" \
        -d "scope=openid urn:zitadel:iam:org:projects:roles urn:zitadel:iam:org:project:id:<PROJECT_ID>:aud" | jq -r .access_token)
      ```
   b. Validate management/catalog calls succeed with the external token and no principal lookup error:
      ```bash
      curl -H "Authorization: Bearer $ZITADEL_TOKEN" https://polaris.gsingh.io/api/management/v1/principals
      curl -H "Authorization: Bearer $ZITADEL_TOKEN" https://polaris.gsingh.io/api/catalog/v1/iceberg/namespaces
      ```

6. Decide final auth mode and apply it explicitly:
   - Option A: keep `mixed` for operational break-glass access.
   - Option B: revert to strict `external` and set `authentication.tokenService.type: disabled`.
   - Record the chosen mode in deployment notes so future operators understand expected behavior.

**Verification**:
- [x] Polaris is temporarily running in `mixed` mode during bootstrap and healthy after sync
- [x] Bootstrap admin principal exists and can mint an internal token
- [x] Script `scripts/init-polaris-catalog.sh` is executable, idempotent, and documented
- [x] Principal exists in Polaris for the Zitadel `sub` claim used by Trino service user
- [x] Principal roles are created and assigned
- [x] Catalog `iceberg` exists with S3 storage configuration
- [x] Namespace `default` exists within the `iceberg` catalog
- [x] External Zitadel token can list namespaces without `Unable to fetch principal entity`
- [x] Final auth mode (`mixed` or `external`) is explicitly set and verified

**Completion Gate**:
> This phase is NOT complete until the user has reviewed the work and explicitly confirmed it is done. Do not proceed to dependent phases or mark this phase as finished without user approval.

**Outputs**:
- Bootstrapped Polaris principals/roles via temporary mixed-auth path
- Initialized Polaris catalog with principals, roles, and namespaces
- Reusable script `scripts/init-polaris-catalog.sh` for repeatable initialization
- Confirmed end-to-end OIDC authentication flow (Zitadel -> Polaris) after principal seeding
- Explicit decision recorded for steady-state auth mode (`mixed` or `external`)

**Git Branch Setup**:
```bash
git checkout -b feature/4-init-polaris-catalog
```

**After completing this phase**:
```bash
git add .
git commit -m "feat: add Polaris catalog initialization script with OIDC auth"
git push -u origin feature/4-init-polaris-catalog
git checkout main
git merge feature/4-init-polaris-catalog
git branch -d feature/4-init-polaris-catalog
```

---

### Phase 5: Switch Trino Iceberg Catalog from JDBC to Polaris REST ✅ COMPLETED

**Objective**: Modify the Trino ArgoCD Application template and values to use Polaris REST catalog instead of the direct JDBC catalog for Iceberg.

**Complexity**: high
**Estimated Time**: 45 min

**Prerequisites**:
- Phase 4 completed (Polaris is running with initialized catalog)
- Polaris REST API is verified accessible from within the cluster

**Context for this Phase**:
- The Trino template is at `charts/root-app/templates/trino.yaml` (88 lines).
- Current Trino values in `charts/root-app/values.yaml` (lines 386-410) configure an Iceberg JDBC catalog.
- The template currently generates these Iceberg catalog properties:
  ```
  connector.name=iceberg
  iceberg.catalog.type=jdbc
  iceberg.jdbc-catalog.connection-url=jdbc:postgresql://...
  iceberg.jdbc-catalog.default-warehouse-dir=s3a://datastore/iceberg
  iceberg.jdbc-catalog.driver-class=org.postgresql.Driver
  iceberg.jdbc-catalog.catalog-name=iceberg
  iceberg.jdbc-catalog.connection-user=${ENV:POSTGRES_USER}
  iceberg.jdbc-catalog.connection-password=${ENV:POSTGRES_PASSWORD}
  fs.native-s3.enabled=true
  s3.endpoint=...
  s3.region=...
  s3.path-style-access=...
  ```
- This needs to change to:
  ```
  connector.name=iceberg
  iceberg.catalog.type=rest
  iceberg.rest-catalog.uri=http://polaris.data-platform.svc.cluster.local:8181/api/catalog
  iceberg.rest-catalog.warehouse=iceberg
  iceberg.rest-catalog.security=OAUTH2
  iceberg.rest-catalog.oauth2.credential=${ENV:POLARIS_OAUTH_CREDENTIAL}
  iceberg.rest-catalog.oauth2.server-uri=https://auth.gsingh.io/oauth/v2/token
  iceberg.rest-catalog.oauth2.scope=openid urn:zitadel:iam:org:projects:roles urn:zitadel:iam:org:project:id:<PROJECT_ID>:aud
  fs.native-s3.enabled=true
  s3.endpoint=...
  s3.region=...
  s3.path-style-access=...
  ```
- The `envFrom` section needs to reference `trino-polaris-oauth` secret (created in Phase 2) instead of (or in addition to) `trino-iceberg-s3`.
- S3 credentials may still be needed by Trino for direct file access, OR Polaris can vend credentials. Determine which approach to use:
  - **Option A**: Trino uses its own S3 credentials (keep `trino-iceberg-s3` envFrom) -- simpler, no vended credentials
  - **Option B**: Polaris vends S3 credentials to Trino (`iceberg.rest-catalog.vended-credentials-enabled=true`) -- more secure, centralized credential management
- The values schema should support both `jdbc` and `rest` catalog types to allow easy rollback.

**Files**:
| File | Action | Purpose |
|------|--------|---------|
| `charts/root-app/templates/trino.yaml` | modify | Update Iceberg catalog config from JDBC to REST |
| `charts/root-app/values.yaml` | modify | Update `trino.catalogs.iceberg` to use REST catalog type |

**Implementation Steps**:
1. Update `charts/root-app/values.yaml` -- modify the `trino.catalogs.iceberg` section:
   ```yaml
   trino:
     enabled: true
     version: "1.42.0"
     namespace: data-platform
     ingress:
       host: trino.gsingh.io
     server:
       workers: 4
     auth:
       enabled: true
       passwordAuthSecret: "trino-password-auth"
       sharedSecretName: "trino-shared-secret"
       groups:
         enabled: false
         groupsAuthSecret: "trino-groups-auth"
     catalogs:
       iceberg:
         enabled: true
         catalogName: iceberg
         catalogType: rest  # Changed from implicit jdbc to explicit rest
         rest:
           uri: http://polaris.data-platform.svc.cluster.local:8181/api/catalog
           warehouse: iceberg
           security: OAUTH2
            oauth2:
              credentialsSecret: trino-polaris-oauth
              serverUri: https://auth.gsingh.io/oauth/v2/token
              scope: "openid urn:zitadel:iam:org:projects:roles urn:zitadel:iam:org:project:id:<PROJECT_ID>:aud"
         s3:
           endpoint: https://s3v2.gsingh.io
           region: us-east-1
           pathStyleAccess: true
         credentialsSecret: trino-iceberg-s3  # Keep for direct S3 access
   ```

2. Update `charts/root-app/templates/trino.yaml` -- modify the catalogs section to support the REST catalog type:
   - Replace the JDBC catalog properties block with REST catalog properties
   - The template should check `$iceberg.catalogType` (defaulting to `rest`) and render the appropriate properties
   - Add `trino-polaris-oauth` to the `envFrom` list
   - Keep `trino-iceberg-s3` in `envFrom` for S3 file access credentials
   - Keep the S3 configuration properties (`fs.native-s3.enabled`, `s3.endpoint`, `s3.region`, `s3.path-style-access`)

3. The updated catalog properties in the template should render as:
   ```yaml
   catalogs:
     {{ default "iceberg" $iceberg.catalogName }}: |
       connector.name=iceberg
       iceberg.catalog.type=rest
       iceberg.rest-catalog.uri={{ $iceberg.rest.uri }}
       iceberg.rest-catalog.warehouse={{ $iceberg.rest.warehouse }}
       iceberg.rest-catalog.security={{ $iceberg.rest.security }}
       iceberg.rest-catalog.oauth2.credential=${ENV:POLARIS_OAUTH_CREDENTIAL}
       iceberg.rest-catalog.oauth2.server-uri={{ $iceberg.rest.oauth2.serverUri }}
       iceberg.rest-catalog.oauth2.scope={{ $iceberg.rest.oauth2.scope }}
       fs.native-s3.enabled=true
       s3.endpoint={{ $icebergS3.endpoint }}
       s3.region={{ $icebergS3.region }}
       s3.path-style-access={{ ternary "true" "false" $icebergS3.pathStyleAccess }}
   ```

4. Update the `envFrom` section to include the Polaris OAuth secret:
   ```yaml
   envFrom:
   - secretRef:
       name: {{ $iceberg.credentialsSecret }}
   - secretRef:
       name: {{ $iceberg.rest.oauth2.credentialsSecret }}
   - secretRef:
       name: {{ $trino.auth.sharedSecretName }}
   ```

5. Run `helm lint charts/root-app/` to validate.

6. Run `just test-render trino` and carefully inspect the rendered output:
   - Verify catalog properties use `rest` type
   - Verify `envFrom` includes both S3 and OAuth secrets
   - Verify S3 properties are still present
   - Verify no JDBC properties remain

7. After ArgoCD syncs, verify Trino can connect to Polaris:
   ```bash
   # Connect to Trino and test
   trino --server https://trino.gsingh.io --user <username> --password
   > SHOW CATALOGS;
   > USE iceberg.default;
   > SHOW TABLES;
   ```

**Verification**:
- [x] `helm lint charts/root-app/` passes
- [x] `just test-render trino` renders without errors
- [x] Rendered catalog properties use `iceberg.catalog.type=rest`
- [x] Rendered catalog properties include `iceberg.rest-catalog.uri` pointing to Polaris
- [x] Rendered catalog properties include OAuth2 configuration
- [x] Rendered `envFrom` includes `trino-polaris-oauth` secret
- [x] No JDBC catalog properties remain in the rendered output
- [x] S3 configuration properties are still present
- [x] After sync: `SHOW CATALOGS` in Trino includes `iceberg`
- [x] After sync: `SHOW SCHEMAS FROM iceberg` returns the `default` namespace from Polaris
- [x] After sync: Creating a table in Trino via Polaris catalog succeeds

**Completion Gate**:
> This phase is NOT complete until the user has reviewed the work and explicitly confirmed it is done. Do not proceed to dependent phases or mark this phase as finished without user approval.

**Outputs**:
- Updated `charts/root-app/templates/trino.yaml` with REST catalog support
- Updated `charts/root-app/values.yaml` with REST catalog configuration
- Trino successfully querying Iceberg tables through Polaris

**Git Branch Setup**:
```bash
git checkout -b feature/5-switch-trino-to-polaris
```

**After completing this phase**:
```bash
git add .
git commit -m "feat: switch Trino Iceberg catalog from JDBC to Polaris REST with OIDC auth"
git push -u origin feature/5-switch-trino-to-polaris
git checkout main
git merge feature/5-switch-trino-to-polaris
git branch -d feature/5-switch-trino-to-polaris
```

---

### Phase 6: Data Migration and Validation ✅ COMPLETED

**Objective**: Migrate existing Iceberg table metadata from the JDBC catalog to Polaris and validate that all existing tables are accessible through the new REST catalog.

**Complexity**: medium
**Estimated Time**: 30 min

**Prerequisites**:
- Phase 5 completed (Trino is connected to Polaris)

**Context for this Phase**:
- If there are existing Iceberg tables registered in the old JDBC catalog (PostgreSQL), their metadata needs to be registered in Polaris.
- Polaris supports registering existing tables via the REST API using `POST /v1/{prefix}/namespaces/{namespace}/register` with the table's metadata location in S3.
- The actual Iceberg data files in S3 (`s3a://datastore/iceberg`) do not need to move -- only the catalog metadata registration changes.
- If no tables exist yet (fresh setup), this phase is a simple verification.
- A migration script should:
  1. Query the old JDBC catalog (PostgreSQL) for existing table metadata
  2. For each table, register it in Polaris using the REST API
  3. Verify the table is accessible through Trino via the new Polaris catalog

**Files**:
| File | Action | Purpose |
|------|--------|---------|
| `scripts/migrate-iceberg-to-polaris.sh` | create | Script to migrate table registrations from JDBC to Polaris |

**Implementation Steps**:
1. **Assess existing tables**: Connect to Trino (or directly to PostgreSQL) and list all existing Iceberg tables and their metadata locations:
   ```sql
   -- In the old JDBC catalog (if still accessible)
   SELECT * FROM iceberg.information_schema.tables;
   ```
   If no tables exist, skip to step 4.

2. **Create migration script** `scripts/migrate-iceberg-to-polaris.sh`:
   - For each existing table, find its metadata location in S3
   - Register the table in Polaris using the REST API:
     ```bash
     curl -X POST "https://polaris.gsingh.io/api/catalog/v1/iceberg/namespaces/{namespace}/register" \
       -H "Authorization: Bearer $TOKEN" \
       -H "Content-Type: application/json" \
       -d '{
         "name": "<table_name>",
         "metadata-location": "s3://datastore/iceberg/<namespace>/<table>/metadata/<version>.metadata.json"
       }'
     ```

3. **Create namespaces in Polaris** for any namespaces that exist in the old catalog but weren't created in Phase 4.

4. **Verify all tables are accessible** through Trino:
   ```sql
   SHOW SCHEMAS FROM iceberg;
   -- For each schema:
   SHOW TABLES FROM iceberg.<schema>;
   -- For each table:
   SELECT * FROM iceberg.<schema>.<table> LIMIT 1;
   ```

5. **Test write operations**:
   ```sql
   CREATE SCHEMA IF NOT EXISTS iceberg.test;
   CREATE TABLE iceberg.test.validation (id INT, name VARCHAR);
   INSERT INTO iceberg.test.validation VALUES (1, 'polaris-test');
   SELECT * FROM iceberg.test.validation;
   DROP TABLE iceberg.test.validation;
   DROP SCHEMA iceberg.test;
   ```

**Verification**:
- [x] All existing Iceberg tables (if any) are registered in Polaris
- [x] All tables are queryable through Trino via the Polaris REST catalog
- [x] Write operations (CREATE TABLE, INSERT, SELECT, DROP) work correctly
- [x] S3 data files are accessible through the new catalog path
- [x] Migration script is documented and reusable (if tables existed)

**Completion Gate**:
> This phase is NOT complete until the user has reviewed the work and explicitly confirmed it is done. Do not proceed to dependent phases or mark this phase as finished without user approval.

**Outputs**:
- All existing Iceberg tables migrated to Polaris (if applicable)
- Verified end-to-end read/write through Trino -> Polaris -> S3
- Migration script for future use

**Git Branch Setup**:
```bash
git checkout -b feature/6-migrate-validate-data
```

**After completing this phase**:
```bash
git add .
git commit -m "feat: add Iceberg table migration script and validate Polaris integration"
git push -u origin feature/6-migrate-validate-data
git checkout main
git merge feature/6-migrate-validate-data
git branch -d feature/6-migrate-validate-data
```

---

### Phase 7: Cleanup and Documentation ✅ COMPLETED

**Objective**: Remove unused JDBC catalog configuration, update AGENTS.md with Polaris documentation, and add Polaris to the justfile recipes.

**Complexity**: low
**Estimated Time**: 20 min

**Prerequisites**:
- Phase 6 completed (migration verified, all tables accessible)

**Context for this Phase**:
- After confirming Polaris works correctly, clean up any leftover JDBC-specific configuration.
- The old PostgreSQL database that Trino used directly for Iceberg metadata (if it was a dedicated database) can be decommissioned. However, if it was shared with other apps, only the Iceberg-specific tables should be cleaned up.
- Update `AGENTS.md` to document Polaris as part of the available applications and data platform architecture.
- Add `just` recipes for common Polaris operations.
- The `trino-iceberg-s3` secret may still be needed if Trino accesses S3 directly. If Polaris vends credentials, this secret can be removed.

**Files**:
| File | Action | Purpose |
|------|--------|---------|
| `charts/root-app/values.yaml` | modify | Clean up any deprecated JDBC-specific values |
| `AGENTS.md` | modify | Add Polaris to available applications and architecture docs |
| `justfile` | modify | Add Polaris helper recipes |

**Implementation Steps**:
1. **Clean up values.yaml**:
   - Remove any JDBC-specific values that are no longer used under `trino.catalogs.iceberg` (e.g., `warehouse` if it was JDBC-specific)
   - Ensure the values are clean and well-commented
   - Add comments explaining the Polaris REST catalog configuration

2. **Update AGENTS.md**:
   - Add Polaris to the "Data & Analytics" section under "Available Applications":
     ```
     - **polaris** - Apache Iceberg REST Catalog (v1.3.0-incubating)
     ```
   - Update the Trino entry to note it uses Polaris:
     ```
     - **trino** - Distributed SQL query engine (via Polaris REST catalog)
     ```
   - Add a note about the data platform architecture (Trino -> Polaris -> S3)

3. **Add justfile recipes**:
   ```just
   # Test render Polaris template
   # (already covered by: just test-render polaris)

   # Initialize Polaris catalog (first-time setup)
   init-polaris:
       ./scripts/init-polaris-catalog.sh
   ```

4. Run `helm lint charts/root-app/` to validate final state.
5. Run `just test-render polaris` and `just test-render trino` to verify both templates still render correctly.

**Verification**:
- [x] `helm lint charts/root-app/` passes
- [x] `just test-render polaris` renders correctly
- [x] `just test-render trino` renders correctly
- [x] No unused JDBC configuration remains in values.yaml
- [x] AGENTS.md includes Polaris documentation
- [x] Justfile includes Polaris recipes
- [x] All scripts are executable (`chmod +x`)

**Completion Gate**:
> This phase is NOT complete until the user has reviewed the work and explicitly confirmed it is done. Do not proceed to dependent phases or mark this phase as finished without user approval.

**Outputs**:
- Clean, well-documented configuration
- Updated project documentation
- Helper recipes in justfile

**Git Branch Setup**:
```bash
git checkout -b feature/7-cleanup-documentation
```

**After completing this phase**:
```bash
git add .
git commit -m "feat: cleanup JDBC config, document Polaris in AGENTS.md, add justfile recipes"
git push -u origin feature/7-cleanup-documentation
git checkout main
git merge feature/7-cleanup-documentation
git branch -d feature/7-cleanup-documentation
```

---

## Phase Dependencies

```
Phase 1 (database + secrets)
    └── Phase 2 (Zitadel OIDC config)
            └── Phase 3 (deploy Polaris)
                    └── Phase 4 (init catalog + verify)
                            └── Phase 5 (switch Trino to Polaris REST)
                                    └── Phase 6 (data migration + validation)
                                            └── Phase 7 (cleanup + docs)
```

All phases are strictly sequential -- each depends on the previous phase's outputs.

## Risks

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| Polaris Helm chart version `1.3.0-incubating` not resolvable by ArgoCD | Deployment fails | Medium | Fall back to Git source approach (point to GitHub repo + tag) instead of Helm repo |
| Zitadel role claim format incompatible with Polaris mapper | Auth fails, no access | Medium | Use `mixed` auth mode initially; configure Zitadel Action to flatten roles; test with `internal` auth first |
| Trino cannot authenticate to Polaris via OAuth2 | Catalog unavailable | Low | Test OAuth2 flow manually with curl before configuring Trino; start with `security=NONE` for initial testing |
| Existing Iceberg tables not accessible after migration | Data loss (metadata only) | Low | Keep old JDBC catalog database intact as backup; register tables in Polaris without deleting from PostgreSQL |
| Polaris performance under load | Query latency increase | Low | Polaris adds one network hop; monitor latency; scale Polaris replicas via HPA if needed |
| S3 credential management conflict | File access denied | Low | Initially use Trino's own S3 credentials (not vended); migrate to vended credentials later |

## Questions for User

1. **Existing Iceberg tables**: Do you currently have any Iceberg tables registered in the JDBC catalog, or is this a fresh setup? This affects the scope of Phase 6.

2. **Zitadel role claim format**: Have you configured custom claims or Actions in Zitadel before? The default role claim format (`urn:zitadel:iam:org:project:roles` as a JSON object) may need a Zitadel Action to flatten into a simple array for Polaris.

3. **Vended credentials**: Do you want Polaris to vend S3 credentials to Trino (more secure, centralized), or should Trino keep its own S3 credentials (simpler, current approach)?

4. **Fallback strategy**: If Polaris has issues, do you want the template to support easy rollback to the JDBC catalog (e.g., a `catalogType: jdbc` flag that switches back)?

5. **Polaris replicas/resources**: Do you have preferences for Polaris resource limits and replica count, or should we start with chart defaults and tune later?
