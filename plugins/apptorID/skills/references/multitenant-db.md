# Multi-Tenant Database — apptorID Model A (Realm per Customer Org)

This is the reference for **Model A**: each customer organization in your application gets its own apptorID realm + app client. You provision each org's realm **at customer-signup time over the HTTP API** (not via MCP — MCP is dev-time only), and you store the resulting per-org configuration in YOUR database so you can route logins and make later admin calls.

> **If you picked Model B (one shared realm + `orgRefId`), you do NOT need this file.** Model B uses a single realm/app client whose credentials live in app config; tenants are distinguished by the `org_id` JWT claim. See `setup/SKILL.md` → "Tenancy Models".

> **Boundary reality:** all realms you create live under your ONE Apptor account, and realms in the same account share JWT signing keys. Model A isolates data (users, app clients, IdPs, branding, password policy) but not cryptography — your app's JWT verifier is the trust boundary, and you authorize per-tenant via the `org_id` claim you choose to set. Hard cryptographic isolation between your customers would require separate Apptor accounts, which only Apptor provisions. See `oidc-knowledge.md`.

> **`realmId` is mandatory in your per-org row.** Every later admin call for that org (`POST /realms/{realmId}/users`, secret rotation, etc.) needs it. Storing only the realm URL + clientId is not enough.

## Table of Contents
1. [Database Schema](#database-schema)
2. [Java/Spring JPA Entity](#javaspring-jpa-entity)
3. [Node.js/Sequelize Model](#nodejssequelize-model)
4. [Node.js/Prisma Schema](#nodejsprisma-schema)
5. [Python/SQLAlchemy Model](#pythonsqlalchemy-model)
6. [Admin API for Managing Configs](#admin-api-for-managing-configs)
7. [Dynamic OIDC Client Factory](#dynamic-oidc-client-factory)
8. [Secret Encryption](#secret-encryption)

---

## Database Schema

### SQL Migration

```sql
-- Multi-tenant apptorID configuration per organization
CREATE TABLE org_auth_config (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id UUID NOT NULL,                          -- FK to your org/tenant table
    realm_id TEXT NOT NULL,                         -- apptorID realm UUID — REQUIRED for all later admin calls
    realm_name TEXT NOT NULL,                       -- apptorID realm display name
    realm_url TEXT NOT NULL,                        -- authDomain, e.g., 'acme-x1y2.sandbox.auth.apptor.io'
    client_id TEXT NOT NULL,                        -- apptorID app client ID
    client_secret_encrypted TEXT NOT NULL,          -- Encrypted client secret
    redirect_uri TEXT NOT NULL,                     -- Callback URL for this org
    enabled_idps JSONB DEFAULT '["local"]'::jsonb,  -- e.g., ["local","google","microsoft"]
    login_type TEXT NOT NULL DEFAULT 'hosted',       -- 'hosted' or 'client'
    login_page_url TEXT,                             -- Only if login_type='client'
    scopes TEXT DEFAULT 'openid email profile',
    access_token_ttl_min INTEGER DEFAULT 60,
    refresh_token_ttl_days INTEGER DEFAULT 30,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    CONSTRAINT fk_org FOREIGN KEY (org_id)
        REFERENCES {{org_table}}({{org_pk}}) ON DELETE CASCADE,
    CONSTRAINT uq_org_auth UNIQUE (org_id)
);

-- Index for quick lookups
CREATE INDEX idx_org_auth_config_org_id ON org_auth_config(org_id);
CREATE INDEX idx_org_auth_config_realm_url ON org_auth_config(realm_url);
CREATE INDEX idx_org_auth_config_realm_id ON org_auth_config(realm_id);

-- Optional: If tenants are identified by subdomain or custom domain
ALTER TABLE org_auth_config ADD COLUMN org_identifier TEXT;
CREATE UNIQUE INDEX idx_org_auth_config_identifier ON org_auth_config(org_identifier) WHERE org_identifier IS NOT NULL;
```

**Replace `{{org_table}}` and `{{org_pk}}` with your actual organization table name and primary key column.**

### Rollback

```sql
DROP INDEX IF EXISTS idx_org_auth_config_identifier;
DROP INDEX IF EXISTS idx_org_auth_config_realm_id;
DROP INDEX IF EXISTS idx_org_auth_config_realm_url;
DROP INDEX IF EXISTS idx_org_auth_config_org_id;
DROP TABLE IF EXISTS org_auth_config;
```

---

## Java/Spring JPA Entity

```java
package {{basePackage}}.model;

import jakarta.persistence.*;
import org.hibernate.annotations.JdbcTypeCode;
import org.hibernate.type.SqlTypes;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

@Entity
@Table(name = "org_auth_config")
public class OrgAuthConfig {

    @Id
    @GeneratedValue(strategy = GenerationType.AUTO)
    private UUID id;

    @Column(name = "org_id", nullable = false, unique = true)
    private UUID orgId;

    @Column(name = "realm_id", nullable = false)
    private String realmId;

    @Column(name = "realm_name", nullable = false)
    private String realmName;

    @Column(name = "realm_url", nullable = false)
    private String realmUrl;

    @Column(name = "client_id", nullable = false)
    private String clientId;

    @Column(name = "client_secret_encrypted", nullable = false)
    private String clientSecretEncrypted;

    @Column(name = "redirect_uri", nullable = false)
    private String redirectUri;

    @JdbcTypeCode(SqlTypes.JSON)
    @Column(name = "enabled_idps", columnDefinition = "jsonb")
    private List<String> enabledIdps = List.of("local");

    @Column(name = "login_type", nullable = false)
    private String loginType = "hosted";

    @Column(name = "login_page_url")
    private String loginPageUrl;

    @Column(name = "scopes")
    private String scopes = "openid email profile";

    @Column(name = "access_token_ttl_min")
    private Integer accessTokenTtlMin = 60;

    @Column(name = "refresh_token_ttl_days")
    private Integer refreshTokenTtlDays = 30;

    @Column(name = "is_active")
    private Boolean isActive = true;

    @Column(name = "org_identifier")
    private String orgIdentifier;

    @Column(name = "created_at")
    private OffsetDateTime createdAt = OffsetDateTime.now();

    @Column(name = "updated_at")
    private OffsetDateTime updatedAt = OffsetDateTime.now();

    // --- Derived properties ---

    @Transient
    public String getRealmBaseUrl() {
        return realmUrl.startsWith("http") ? realmUrl : "https://" + realmUrl;
    }

    @Transient
    public String getDiscoveryUrl() {
        return getRealmBaseUrl() + "/.well-known/openid-configuration";
    }

    // Standard getters/setters omitted for brevity — generate them
}
```

### Repository

```java
package {{basePackage}}.repository;

import {{basePackage}}.model.OrgAuthConfig;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

import java.util.Optional;
import java.util.UUID;

@Repository
public interface OrgAuthConfigRepository extends JpaRepository<OrgAuthConfig, UUID> {
    Optional<OrgAuthConfig> findByOrgId(UUID orgId);
    Optional<OrgAuthConfig> findByOrgId(String orgId);
    Optional<OrgAuthConfig> findByOrgIdentifier(String orgIdentifier);
    Optional<OrgAuthConfig> findByRealmUrl(String realmUrl);
    Optional<OrgAuthConfig> findByRealmId(String realmId);
    boolean existsByOrgId(UUID orgId);
}
```

---

## Node.js/Sequelize Model

```typescript
// models/OrgAuthConfig.ts
import { DataTypes, Model } from 'sequelize';
import { sequelize } from '../db';

export class OrgAuthConfig extends Model {
  declare id: string;
  declare orgId: string;
  declare realmId: string;
  declare realmName: string;
  declare realmUrl: string;
  declare clientId: string;
  declare clientSecretEncrypted: string;
  declare redirectUri: string;
  declare enabledIdps: string[];
  declare loginType: 'hosted' | 'client';
  declare loginPageUrl: string | null;
  declare scopes: string;
  declare accessTokenTtlMin: number;
  declare refreshTokenTtlDays: number;
  declare isActive: boolean;
  declare orgIdentifier: string | null;

  get realmBaseUrl(): string {
    return this.realmUrl.startsWith('http') ? this.realmUrl : `https://${this.realmUrl}`;
  }

  get discoveryUrl(): string {
    return `${this.realmBaseUrl}/.well-known/openid-configuration`;
  }
}

OrgAuthConfig.init(
  {
    id: { type: DataTypes.UUID, defaultValue: DataTypes.UUIDV4, primaryKey: true },
    orgId: { type: DataTypes.UUID, allowNull: false, unique: true, field: 'org_id' },
    realmId: { type: DataTypes.TEXT, allowNull: false, field: 'realm_id' },
    realmName: { type: DataTypes.TEXT, allowNull: false, field: 'realm_name' },
    realmUrl: { type: DataTypes.TEXT, allowNull: false, field: 'realm_url' },
    clientId: { type: DataTypes.TEXT, allowNull: false, field: 'client_id' },
    clientSecretEncrypted: { type: DataTypes.TEXT, allowNull: false, field: 'client_secret_encrypted' },
    redirectUri: { type: DataTypes.TEXT, allowNull: false, field: 'redirect_uri' },
    enabledIdps: { type: DataTypes.JSONB, defaultValue: ['local'], field: 'enabled_idps' },
    loginType: { type: DataTypes.TEXT, defaultValue: 'hosted', field: 'login_type' },
    loginPageUrl: { type: DataTypes.TEXT, allowNull: true, field: 'login_page_url' },
    scopes: { type: DataTypes.TEXT, defaultValue: 'openid email profile' },
    accessTokenTtlMin: { type: DataTypes.INTEGER, defaultValue: 60, field: 'access_token_ttl_min' },
    refreshTokenTtlDays: { type: DataTypes.INTEGER, defaultValue: 30, field: 'refresh_token_ttl_days' },
    isActive: { type: DataTypes.BOOLEAN, defaultValue: true, field: 'is_active' },
    orgIdentifier: { type: DataTypes.TEXT, allowNull: true, field: 'org_identifier' },
  },
  { sequelize, tableName: 'org_auth_config', timestamps: true, underscored: true }
);
```

---

## Node.js/Prisma Schema

```prisma
// Add to schema.prisma
model OrgAuthConfig {
  id                    String   @id @default(uuid())
  orgId                 String   @unique @map("org_id")
  realmId               String   @map("realm_id")
  realmName             String   @map("realm_name")
  realmUrl              String   @map("realm_url")
  clientId              String   @map("client_id")
  clientSecretEncrypted String   @map("client_secret_encrypted")
  redirectUri           String   @map("redirect_uri")
  enabledIdps           Json     @default("[\"local\"]") @map("enabled_idps")
  loginType             String   @default("hosted") @map("login_type")
  loginPageUrl          String?  @map("login_page_url")
  scopes                String   @default("openid email profile")
  accessTokenTtlMin     Int      @default(60) @map("access_token_ttl_min")
  refreshTokenTtlDays   Int      @default(30) @map("refresh_token_ttl_days")
  isActive              Boolean  @default(true) @map("is_active")
  orgIdentifier         String?  @unique @map("org_identifier")
  createdAt             DateTime @default(now()) @map("created_at")
  updatedAt             DateTime @updatedAt @map("updated_at")

  // Add foreign key to your org model:
  // org Organization @relation(fields: [orgId], references: [id], onDelete: Cascade)

  @@map("org_auth_config")
  @@index([orgId])
  @@index([realmUrl])
  @@index([realmId])
}
```

---

## Python/SQLAlchemy Model

```python
# models/org_auth_config.py
import uuid
from datetime import datetime, timezone
from sqlalchemy import Column, String, Boolean, Integer, DateTime, JSON, ForeignKey, UniqueConstraint, Index
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import relationship
from db import Base


class OrgAuthConfig(Base):
    __tablename__ = "org_auth_config"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    org_id = Column(UUID(as_uuid=True), ForeignKey("{{org_table}}.{{org_pk}}", ondelete="CASCADE"), nullable=False, unique=True)
    realm_id = Column(String, nullable=False)
    realm_name = Column(String, nullable=False)
    realm_url = Column(String, nullable=False)
    client_id = Column(String, nullable=False)
    client_secret_encrypted = Column(String, nullable=False)
    redirect_uri = Column(String, nullable=False)
    enabled_idps = Column(JSON, default=["local"])
    login_type = Column(String, nullable=False, default="hosted")
    login_page_url = Column(String, nullable=True)
    scopes = Column(String, default="openid email profile")
    access_token_ttl_min = Column(Integer, default=60)
    refresh_token_ttl_days = Column(Integer, default=30)
    is_active = Column(Boolean, default=True)
    org_identifier = Column(String, nullable=True, unique=True)
    created_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))
    updated_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc), onupdate=lambda: datetime.now(timezone.utc))

    __table_args__ = (
        Index("idx_org_auth_config_org_id", "org_id"),
        Index("idx_org_auth_config_realm_url", "realm_url"),
        Index("idx_org_auth_config_realm_id", "realm_id"),
    )

    @property
    def realm_base_url(self) -> str:
        return self.realm_url if self.realm_url.startswith("http") else f"https://{self.realm_url}"

    @property
    def discovery_url(self) -> str:
        return f"{self.realm_base_url}/.well-known/openid-configuration"
```

### FastAPI Repository

```python
# repositories/org_auth_config_repo.py
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from models.org_auth_config import OrgAuthConfig


class OrgAuthConfigRepository:
    def __init__(self, session: AsyncSession):
        self.session = session

    async def find_by_org_id(self, org_id: str) -> OrgAuthConfig | None:
        result = await self.session.execute(
            select(OrgAuthConfig).where(OrgAuthConfig.org_id == org_id)
        )
        return result.scalar_one_or_none()

    async def find_by_identifier(self, identifier: str) -> OrgAuthConfig | None:
        result = await self.session.execute(
            select(OrgAuthConfig).where(OrgAuthConfig.org_identifier == identifier)
        )
        return result.scalar_one_or_none()

    async def find_by_realm_url(self, realm_url: str) -> OrgAuthConfig | None:
        result = await self.session.execute(
            select(OrgAuthConfig).where(OrgAuthConfig.realm_url == realm_url)
        )
        return result.scalar_one_or_none()

    async def save(self, config: OrgAuthConfig) -> OrgAuthConfig:
        self.session.add(config)
        await self.session.commit()
        await self.session.refresh(config)
        return config

    async def delete_by_org_id(self, org_id: str) -> None:
        config = await self.find_by_org_id(org_id)
        if config:
            await self.session.delete(config)
            await self.session.commit()
```

---

## Runtime Org Onboarding Service (the core of Model A)

When a new customer org signs up, your app provisions its realm over the **HTTP API** using the single access key Apptor gave you (bound to your one account). MCP is NOT used at runtime. The sequence:

1. Mint an admin token: `POST /oidc/token` `grant_type=client_credentials` with `access_key_id` + `access_key_secret` (form-encoded). The token's `account_id` claim is your account — you need it for the realm-create path.
2. `POST /accounts/{accountId}/realms` → realm (`realmId`, `authDomain`)
3. `POST /realms/{realmId}/app-clients` with `idpClient:false, multiTenant:false` → `clientId`, `clientSecret` (secret shown once)
4. `POST /app-clients/{clientId}/url-type/{login|redirect|logout}/app-urls` → register URLs BEFORE first login
5. `POST /app-clients/{clientId}/idp-connections` per IdP (optional)
6. `POST /realms/{realmId}/users` → the org's first admin user (optionally with `orgRefId`/`userRefId`)
7. Encrypt `clientSecret`, persist the `org_auth_config` row (including `realmId` + `realmName`)

> Auth note: your access key carries `realm_manage` scoped to your account, so all these calls succeed for any realm under your account. They will 403 if you target another account — which you can't, because the token's `account_id` is fixed.

> Endpoint shapes are authoritative in the live OpenAPI spec (`/swagger/apptor-auth-server-0.5.yml`). The paths below are verified against the server but always cross-check the live spec.

### Spring Boot example

```java
@Service
public class OrgOnboardingService {

    private final OrgAuthConfigRepository repository;
    private final EncryptionService encryptionService;
    private final WebClient web;            // baseUrl = your account's realm/master URL
    private final String accessKeyId;       // from config — Apptor-issued, one per account
    private final String accessKeySecret;   // from config — encrypted at rest / secret manager
    private final String authBaseUrl;       // e.g. https://master.sandbox.auth.apptor.io

    /** Provision a brand-new apptorID realm for a customer org and persist its config. */
    public OrgAuthConfig onboard(UUID orgId, String orgDisplayName,
                                 String appCallbackUrl, String appLoginUrl, String appLogoutUrl,
                                 List<String> idps) {
        String token = mintAdminToken();
        String accountId = accountIdFromToken(token);   // decode the account_id claim

        // 2. Create the realm
        Map<String, Object> realm = web.post()
            .uri(authBaseUrl + "/accounts/{accountId}/realms", accountId)
            .header("Authorization", "Bearer " + token)
            .bodyValue(Map.of(
                "realmName", orgDisplayName,
                "defaultPasswordPolicy", true))      // password policy is required on create
            .retrieve().bodyToMono(Map.class).block();
        String realmId   = (String) realm.get("realmId");
        String authDomain = (String) realm.get("authDomain");

        // 3. Create the app client — flags always false
        Map<String, Object> client = web.post()
            .uri(authBaseUrl + "/realms/{realmId}/app-clients", realmId)
            .header("Authorization", "Bearer " + token)
            .bodyValue(Map.of(
                "name", orgDisplayName + " App",
                "appType", "web",                    // spa | web | mobile | m2m
                "realmId", realmId,
                "idpClient", false,
                "multiTenant", false))
            .retrieve().bodyToMono(Map.class).block();
        String clientId     = (String) client.get("clientId");
        String clientSecret = (String) client.get("clientSecret");   // shown once

        // 4. Register URLs BEFORE any login test (type is in the path; body is a list)
        addUrl(token, clientId, "redirect", appCallbackUrl);
        addUrl(token, clientId, "login",    appLoginUrl);
        addUrl(token, clientId, "logout",   appLogoutUrl);

        // 5. Connect IdPs (optional). For microsoft pass tenantId; google needs client id+secret.
        // for (String idp : idps) addIdpConnection(token, clientId, idp, ...);

        // 7. Persist — REQUIRED: realmId + realmName, secret encrypted
        OrgAuthConfig cfg = new OrgAuthConfig();
        cfg.setOrgId(orgId);
        cfg.setRealmId(realmId);
        cfg.setRealmName(orgDisplayName);
        cfg.setRealmUrl(authDomain);
        cfg.setClientId(clientId);
        cfg.setClientSecretEncrypted(encryptionService.encrypt(clientSecret));
        cfg.setRedirectUri(appCallbackUrl);
        cfg.setEnabledIdps(idps);
        return repository.save(cfg);
    }

    private String mintAdminToken() {
        Map<String, Object> resp = web.post()
            .uri(authBaseUrl + "/oidc/token")
            .header("Content-Type", "application/x-www-form-urlencoded")
            .bodyValue("grant_type=client_credentials"
                + "&access_key_id=" + accessKeyId
                + "&access_key_secret=" + accessKeySecret)
            .retrieve().bodyToMono(Map.class).block();
        return (String) resp.get("access_token");
    }

    private void addUrl(String token, String clientId, String type, String url) {
        if (url == null || url.isBlank()) return;
        web.post()
            .uri(authBaseUrl + "/app-clients/{clientId}/url-type/{type}/app-urls", clientId, type)
            .header("Authorization", "Bearer " + token)
            .bodyValue(List.of(Map.of("type", type, "url", url, "appClientId", clientId)))
            .retrieve().bodyToMono(Object.class).block();
    }

    /** Decode the account_id claim from the admin JWT (verify signature in real code). */
    private String accountIdFromToken(String jwt) {
        String payload = new String(Base64.getUrlDecoder()
            .decode(jwt.split("\\.")[1]), StandardCharsets.UTF_8);
        // parse JSON, return the "account_id" field
        return JsonPath.read(payload, "$.account_id");
    }
}
```

The same call sequence applies in Node/Python/etc. — only the HTTP client differs. Key invariants for any language:
- App client created with `idpClient:false, multiTenant:false`.
- URLs registered before first login (`redirect`, `login`, `logout`).
- Store `realmId` + `realmName` + encrypted secret in your row.
- `accountId` for the realm-create path comes from the admin token's `account_id` claim — you do not hardcode it.

## Admin API for Managing Configs

Endpoints for org admins to configure their apptorID connection:

### Spring Boot

```java
@RestController
@RequestMapping("/api/admin/auth-config")
public class OrgAuthConfigController {

    private final OrgAuthConfigRepository repository;
    private final EncryptionService encryptionService;

    // GET — fetch config for current org
    @GetMapping
    public ResponseEntity<OrgAuthConfigDto> getConfig(@AuthenticationPrincipal UserPrincipal user) {
        return repository.findByOrgId(user.getOrgId())
                .map(config -> ResponseEntity.ok(toDto(config)))
                .orElse(ResponseEntity.notFound().build());
    }

    // PUT — create or update config
    @PutMapping
    public ResponseEntity<OrgAuthConfigDto> saveConfig(
            @AuthenticationPrincipal UserPrincipal user,
            @RequestBody OrgAuthConfigRequest request) {
        OrgAuthConfig config = repository.findByOrgId(user.getOrgId())
                .orElse(new OrgAuthConfig());

        config.setOrgId(user.getOrgId());
        config.setRealmUrl(request.getRealmUrl());
        config.setClientId(request.getClientId());
        if (request.getClientSecret() != null) {
            config.setClientSecretEncrypted(encryptionService.encrypt(request.getClientSecret()));
        }
        config.setRedirectUri(request.getRedirectUri());
        config.setEnabledIdps(request.getEnabledIdps());
        config.setLoginType(request.getLoginType());
        config.setLoginPageUrl(request.getLoginPageUrl());

        return ResponseEntity.ok(toDto(repository.save(config)));
    }

    // DELETE — remove config
    @DeleteMapping
    public ResponseEntity<Void> deleteConfig(@AuthenticationPrincipal UserPrincipal user) {
        repository.findByOrgId(user.getOrgId()).ifPresent(repository::delete);
        return ResponseEntity.noContent().build();
    }

    // POST — test connection (verify realm is reachable)
    @PostMapping("/test")
    public ResponseEntity<Map<String, Object>> testConnection(@RequestBody Map<String, String> request) {
        try {
            String discoveryUrl = request.get("realmUrl");
            if (!discoveryUrl.startsWith("http")) discoveryUrl = "https://" + discoveryUrl;
            discoveryUrl += "/.well-known/openid-configuration";

            // Fetch discovery to verify connectivity
            RestTemplate restTemplate = new RestTemplate();
            Map<String, Object> discovery = restTemplate.getForObject(discoveryUrl, Map.class);
            return ResponseEntity.ok(Map.of("success", true, "issuer", discovery.get("issuer")));
        } catch (Exception e) {
            return ResponseEntity.ok(Map.of("success", false, "error", e.getMessage()));
        }
    }
}
```

---

## Dynamic OIDC Client Factory

For multi-tenant setups, create OIDC clients dynamically based on the org's config:

```java
@Service
public class MultiTenantOidcClientFactory {

    private final OrgAuthConfigRepository configRepository;
    private final EncryptionService encryptionService;
    private final Map<String, ApptorOidcClient> clientCache = new ConcurrentHashMap<>();

    /**
     * Get or create an OIDC client for the given organization.
     * Clients are cached per org for performance.
     */
    public ApptorOidcClient getClientForOrg(String orgId) {
        return clientCache.computeIfAbsent(orgId, id -> {
            OrgAuthConfig config = configRepository.findByOrgId(UUID.fromString(id))
                    .orElseThrow(() -> new RuntimeException("No auth config for org: " + id));

            ApptorAuthProperties props = new ApptorAuthProperties();
            props.setRealmUrl(config.getRealmUrl());
            props.setClientId(config.getClientId());
            props.setClientSecret(encryptionService.decrypt(config.getClientSecretEncrypted()));
            props.setRedirectUri(config.getRedirectUri());
            props.setScopes(config.getScopes());

            ApptorOidcClient client = new ApptorOidcClient(props, WebClient.builder());
            client.fetchDiscovery();
            return client;
        });
    }

    /**
     * Invalidate cached client when org config changes.
     */
    public void invalidateCache(String orgId) {
        clientCache.remove(orgId);
    }
}
```

---

## Secret Encryption

Client secrets must be encrypted at rest. Here's a simple AES-256-GCM implementation:

### Java

```java
@Service
public class EncryptionService {

    private final SecretKey secretKey;

    public EncryptionService(@Value("${encryption.key}") String base64Key) {
        byte[] keyBytes = Base64.getDecoder().decode(base64Key);
        this.secretKey = new SecretKeySpec(keyBytes, "AES");
    }

    public String encrypt(String plaintext) {
        try {
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            byte[] iv = new byte[12];
            new SecureRandom().nextBytes(iv);
            cipher.init(Cipher.ENCRYPT_MODE, secretKey, new GCMParameterSpec(128, iv));
            byte[] encrypted = cipher.doFinal(plaintext.getBytes(StandardCharsets.UTF_8));

            // Prepend IV to ciphertext
            byte[] combined = new byte[iv.length + encrypted.length];
            System.arraycopy(iv, 0, combined, 0, iv.length);
            System.arraycopy(encrypted, 0, combined, iv.length, encrypted.length);
            return Base64.getEncoder().encodeToString(combined);
        } catch (Exception e) {
            throw new RuntimeException("Encryption failed", e);
        }
    }

    public String decrypt(String ciphertext) {
        try {
            byte[] combined = Base64.getDecoder().decode(ciphertext);
            byte[] iv = new byte[12];
            byte[] encrypted = new byte[combined.length - 12];
            System.arraycopy(combined, 0, iv, 0, 12);
            System.arraycopy(combined, 12, encrypted, 0, encrypted.length);

            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.DECRYPT_MODE, secretKey, new GCMParameterSpec(128, iv));
            return new String(cipher.doFinal(encrypted), StandardCharsets.UTF_8);
        } catch (Exception e) {
            throw new RuntimeException("Decryption failed", e);
        }
    }

    /**
     * Generate a new encryption key (run once, store in env):
     * KeyGenerator gen = KeyGenerator.getInstance("AES");
     * gen.init(256);
     * String key = Base64.getEncoder().encodeToString(gen.generateKey().getEncoded());
     */
}
```

### Node.js

```typescript
import crypto from 'crypto';

const ALGORITHM = 'aes-256-gcm';
const IV_LENGTH = 12;
const TAG_LENGTH = 16;
const ENCRYPTION_KEY = Buffer.from(process.env.ENCRYPTION_KEY!, 'base64'); // 32 bytes

export function encrypt(plaintext: string): string {
  const iv = crypto.randomBytes(IV_LENGTH);
  const cipher = crypto.createCipheriv(ALGORITHM, ENCRYPTION_KEY, iv);
  const encrypted = Buffer.concat([cipher.update(plaintext, 'utf8'), cipher.final()]);
  const tag = cipher.getAuthTag();
  return Buffer.concat([iv, tag, encrypted]).toString('base64');
}

export function decrypt(ciphertext: string): string {
  const buf = Buffer.from(ciphertext, 'base64');
  const iv = buf.subarray(0, IV_LENGTH);
  const tag = buf.subarray(IV_LENGTH, IV_LENGTH + TAG_LENGTH);
  const encrypted = buf.subarray(IV_LENGTH + TAG_LENGTH);
  const decipher = crypto.createDecipheriv(ALGORITHM, ENCRYPTION_KEY, iv);
  decipher.setAuthTag(tag);
  return decipher.update(encrypted) + decipher.final('utf8');
}

// Generate key: crypto.randomBytes(32).toString('base64')
```

### Python

```python
import os
import base64
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

ENCRYPTION_KEY = base64.b64decode(os.environ["ENCRYPTION_KEY"])  # 32 bytes


def encrypt(plaintext: str) -> str:
    nonce = os.urandom(12)
    aesgcm = AESGCM(ENCRYPTION_KEY)
    ciphertext = aesgcm.encrypt(nonce, plaintext.encode("utf-8"), None)
    return base64.b64encode(nonce + ciphertext).decode("ascii")


def decrypt(ciphertext_b64: str) -> str:
    data = base64.b64decode(ciphertext_b64)
    nonce = data[:12]
    ciphertext = data[12:]
    aesgcm = AESGCM(ENCRYPTION_KEY)
    return aesgcm.decrypt(nonce, ciphertext, None).decode("utf-8")


# Generate key: base64.b64encode(os.urandom(32)).decode()
```
