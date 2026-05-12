# Secret Management

Where the `OBSERVEKIT_API_KEY` actually lives at runtime, across deployment targets.

## The big rule

**The API key value never goes in a committed file.**

The plugin writes references (e.g., `${OBSERVEKIT_API_KEY}`) into committed config. The actual value lives in the secret store of the target environment, or — for solo local development — in a gitignored local file.

If you see the literal key value in a `Dockerfile`, `application.yml`, `appsettings.json`, `compose.yml`, or any file tracked by git, that is a leak. Rotate the key, then move the value out.

---

## Kubernetes Secret

Create the secret:

```bash
kubectl create secret generic observekit \
  --from-literal=api-key='<your-key>' \
  -n <your-namespace>
```

Reference it from a Deployment:

```yaml
spec:
  template:
    spec:
      containers:
        - name: app
          env:
            - name: OBSERVEKIT_API_KEY
              valueFrom:
                secretKeyRef:
                  name: observekit
                  key: api-key
            - name: OTEL_EXPORTER_OTLP_HEADERS
              value: "X-API-Key=$(OBSERVEKIT_API_KEY)"
```

Note the `$(OBSERVEKIT_API_KEY)` substitution syntax in the second env entry — Kubernetes substitutes env vars defined earlier in the same container's env list.

---

## HashiCorp Vault

Store under a kv-v2 path:

```bash
vault kv put secret/observekit api_key='<your-key>'
```

Inject via the **Vault Agent Injector** (annotations on the pod template):

```yaml
metadata:
  annotations:
    vault.hashicorp.com/agent-inject: "true"
    vault.hashicorp.com/role: "observekit"
    vault.hashicorp.com/agent-inject-secret-observekit: "secret/data/observekit"
    vault.hashicorp.com/agent-inject-template-observekit: |
      {{- with secret "secret/data/observekit" -}}
      export OBSERVEKIT_API_KEY="{{ .Data.data.api_key }}"
      {{- end }}
```

The agent renders a file at `/vault/secrets/observekit`. Source it from the container entrypoint to expose `OBSERVEKIT_API_KEY` as an environment variable.

Vault-as-env-var pattern (simpler, no template): use a sidecar that runs `vault kv get -field=api_key secret/observekit` and writes to a shared `tmpfs` volume the app reads at startup.

---

## AWS Secrets Manager

Create the secret (CloudFormation):

```yaml
ObserveKitApiKey:
  Type: AWS::SecretsManager::Secret
  Properties:
    Name: observekit/api-key
    SecretString: '{"api_key":"<your-key>"}'
```

**IAM permissions** required on the task / pod role:

```json
{
  "Effect": "Allow",
  "Action": ["secretsmanager:GetSecretValue"],
  "Resource": "arn:aws:secretsmanager:<region>:<acct>:secret:observekit/api-key-*"
}
```

**ECS** can inject the secret directly into the task env via the `secrets` block on the container definition — no SDK call needed. **EKS** with Pod Identity (or IRSA) lets the app read the secret via the AWS SDK at boot, or via the AWS Secrets and Configuration Provider (ASCP) for the CSI driver, which mounts it as a file or env var.

---

## Azure Key Vault

Create the secret:

```bash
az keyvault secret set \
  --vault-name <vault-name> \
  --name observekit-api-key \
  --value '<your-key>'
```

**Azure App Service / Container Apps** support Key Vault references natively in app settings:

```
OBSERVEKIT_API_KEY = @Microsoft.KeyVault(SecretUri=https://<vault-name>.vault.azure.net/secrets/observekit-api-key/)
```

The platform resolves the reference at startup and exposes the resolved value to the app as a normal environment variable. The app needs the Key Vault Secrets User role on the vault (assign via managed identity).

For **AKS**, use the Secrets Store CSI Driver with the Azure provider — same idea as ASCP on EKS.

---

## GCP Secret Manager

Create the secret:

```bash
echo -n '<your-key>' | gcloud secrets create observekit-api-key --data-file=-
```

**Cloud Run** can mount the secret as an env var directly:

```bash
gcloud run deploy <service> \
  --update-secrets=OBSERVEKIT_API_KEY=observekit-api-key:latest
```

**GKE** uses Workload Identity to bind a Kubernetes service account to a Google service account, then reads via the Google SDK or the Secrets Store CSI Driver. The bound GSA needs the `roles/secretmanager.secretAccessor` role on the secret.

---

## GitHub Actions

Repository → **Settings → Secrets and variables → Actions → New repository secret**. Name it `OBSERVEKIT_API_KEY`.

Use in a workflow:

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    env:
      OBSERVEKIT_API_KEY: ${{ secrets.OBSERVEKIT_API_KEY }}
    steps:
      - run: ./run-integration-tests.sh
```

GitHub redacts the value from logs automatically. Never `echo` the secret to verify it.

For **organization-wide** secrets (multiple repos), use Organization secrets and scope them to selected repositories.

---

## .NET user-secrets (local dev only)

For local development on a developer's machine, the .NET SDK has built-in user-secrets storage outside the repository:

```bash
dotnet user-secrets init                               # one-time per project
dotnet user-secrets set "OBSERVEKIT_API_KEY" "<your-key>"
```

The value is stored under `%APPDATA%\Microsoft\UserSecrets\<id>\secrets.json` (Windows) or `~/.microsoft/usersecrets/<id>/secrets.json` (Linux/macOS). It integrates with `IConfiguration` transparently in `Development` environment — no code change needed.

**Do not** use user-secrets in production. Use Azure Key Vault, AWS Secrets Manager, or whatever the target environment provides.

---

## Gitignored local file (solo dev fallback)

For solo development without a secret store, a gitignored local file is acceptable. The plugin verifies the file is gitignored before writing to it.

**Typical filenames and the `.gitignore` lines that cover them:**

```gitignore
# Local-only env files (never committed)
.env.local
.env.*.local

# Local-only config overlays
application-local.yml
application-local.yaml
application-local.properties
appsettings.Local.json
*.local.json

# IDE / language local-secret stores
.dotnet/secrets/
```

Rules for this pattern:
- The file must be in `.gitignore` **before** the secret is written.
- The file lives next to the app's other config, not in `~/`.
- Document for the team that this file is local-only — onboarding new contributors must point at the secret store, not at copying the file.
- CI must not depend on this file. CI uses the platform secret store (GitHub Actions / GitLab CI variables / etc.).

This pattern is **not** an alternative to a real secret store. It is a convenience for a solo developer's laptop.
