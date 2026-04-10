# Java Micronaut — apptorID Integration Templates

Since apptorID itself is built on Micronaut, this is the most natural integration. You can also use the **apptor-authserver-sdk-java** client SDK for a faster setup.

## Table of Contents
1. [Option A: Using the apptorID Java SDK](#option-a-using-the-apptor-id-java-sdk)
2. [Option B: Manual Integration](#option-b-manual-integration)

---

## Option A: Using the apptorID Java SDK

The apptorID project provides a Java client SDK (`apptor-authserver-sdk-java`) that handles OIDC discovery, token exchange, and admin API calls.

### Dependency

Add to `build.gradle`:
```groovy
repositories {
    // Apptor's S3 Maven repository (or your internal Nexus/Artifactory)
    maven { url "s3://your-apptor-sdk-repo" }
}

dependencies {
    implementation 'io.apptor:apptor-authserver-sdk-java:1.0.0'
}
```

### Usage

```java
package {{basePackage}}.auth;

import io.apptor.authserver.client.OidcClient;
import io.apptor.authserver.client.IntegrationConfig;
import io.micronaut.context.annotation.Factory;
import io.micronaut.context.annotation.Value;
import jakarta.inject.Singleton;

@Factory
public class ApptorClientFactory {

    @Value("${apptor.auth.realm-url}")
    private String realmUrl;

    @Value("${apptor.auth.client-id}")
    private String clientId;

    @Value("${apptor.auth.client-secret}")
    private String clientSecret;

    @Singleton
    public OidcClient oidcClient() throws Exception {
        // The SDK auto-discovers all endpoints via /.well-known/openid-configuration
        return new OidcClient(realmUrl, clientId, clientSecret);
    }
}
```

The SDK's `OidcClient` provides:
- `callDiscoveryAPI(authDomain)` — fetches OIDC metadata
- Token exchange methods
- Admin API client for realm/user/app-client management

### Integration Config for M2M

```java
IntegrationConfig config = IntegrationConfig.builder()
    .authorize(realmUrl)  // auto-discovers endpoints
    .clientId(clientId)
    .clientSecret(clientSecret)
    .build();
```

---

## Option B: Manual Integration

If you prefer not to use the SDK, here's the full manual integration.

### Dependencies

```groovy
dependencies {
    implementation("io.micronaut:micronaut-http-client")
    implementation("io.micronaut.security:micronaut-security-jwt")
    implementation("com.nimbusds:nimbus-jose-jwt:9.37")
    implementation("io.micronaut:micronaut-session")
}
```

### Configuration

```yaml
# application.yml
apptor:
  auth:
    realm-url: ${APPTOR_REALM_URL}
    client-id: ${APPTOR_CLIENT_ID}
    client-secret: ${APPTOR_CLIENT_SECRET}
    redirect-uri: ${APP_BASE_URL}/auth/callback
    scopes: openid,email,profile
    post-login-uri: /dashboard
    post-logout-uri: /
```

### Config Properties

```java
package {{basePackage}}.config;

import io.micronaut.context.annotation.ConfigurationProperties;

@ConfigurationProperties("apptor.auth")
public class ApptorAuthConfig {
    private String realmUrl;
    private String clientId;
    private String clientSecret;
    private String redirectUri;
    private String scopes = "openid,email,profile";
    private String postLoginUri = "/dashboard";
    private String postLogoutUri = "/";

    public String getRealmBaseUrl() {
        return realmUrl.startsWith("http") ? realmUrl : "https://" + realmUrl;
    }

    public String getDiscoveryUrl() {
        return getRealmBaseUrl() + "/.well-known/openid-configuration";
    }

    // Standard getters/setters
    public String getRealmUrl() { return realmUrl; }
    public void setRealmUrl(String realmUrl) { this.realmUrl = realmUrl; }
    public String getClientId() { return clientId; }
    public void setClientId(String clientId) { this.clientId = clientId; }
    public String getClientSecret() { return clientSecret; }
    public void setClientSecret(String clientSecret) { this.clientSecret = clientSecret; }
    public String getRedirectUri() { return redirectUri; }
    public void setRedirectUri(String redirectUri) { this.redirectUri = redirectUri; }
    public String getScopes() { return scopes; }
    public void setScopes(String scopes) { this.scopes = scopes; }
    public String getPostLoginUri() { return postLoginUri; }
    public void setPostLoginUri(String postLoginUri) { this.postLoginUri = postLoginUri; }
    public String getPostLogoutUri() { return postLogoutUri; }
    public void setPostLogoutUri(String postLogoutUri) { this.postLogoutUri = postLogoutUri; }
}
```

### OIDC Client Service

```java
package {{basePackage}}.auth;

import {{basePackage}}.config.ApptorAuthConfig;
import com.fasterxml.jackson.databind.JsonNode;
import io.micronaut.http.HttpRequest;
import io.micronaut.http.MediaType;
import io.micronaut.http.client.HttpClient;
import io.micronaut.http.client.annotation.Client;
import jakarta.annotation.PostConstruct;
import jakarta.inject.Singleton;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

@Singleton
public class ApptorOidcClient {
    private static final Logger LOG = LoggerFactory.getLogger(ApptorOidcClient.class);

    private final ApptorAuthConfig config;
    private final HttpClient httpClient;
    private final Map<String, String> discovery = new ConcurrentHashMap<>();

    public ApptorOidcClient(ApptorAuthConfig config, @Client HttpClient httpClient) {
        this.config = config;
        this.httpClient = httpClient;
    }

    @PostConstruct
    public void init() {
        fetchDiscovery();
    }

    public void fetchDiscovery() {
        JsonNode doc = httpClient.toBlocking().retrieve(
                HttpRequest.GET(config.getDiscoveryUrl()), JsonNode.class);
        discovery.put("authorization_endpoint", doc.get("authorization_endpoint").asText());
        discovery.put("token_endpoint", doc.get("token_endpoint").asText());
        discovery.put("userinfo_endpoint", doc.get("userinfo_endpoint").asText());
        discovery.put("jwks_uri", doc.get("jwks_uri").asText());
        discovery.put("end_session_endpoint", doc.get("end_session_endpoint").asText());
        discovery.put("issuer", doc.get("issuer").asText());
        LOG.info("apptorID discovery loaded: {}", config.getDiscoveryUrl());
    }

    public String getAuthorizationEndpoint() { return discovery.get("authorization_endpoint"); }
    public String getTokenEndpoint() { return discovery.get("token_endpoint"); }
    public String getUserInfoEndpoint() { return discovery.get("userinfo_endpoint"); }
    public String getJwksUri() { return discovery.get("jwks_uri"); }
    public String getEndSessionEndpoint() { return discovery.get("end_session_endpoint"); }
    public String getIssuer() { return discovery.get("issuer"); }

    public String buildAuthorizationUrl(String state, String codeChallenge, String nonce) {
        return getAuthorizationEndpoint()
                + "?client_id=" + config.getClientId()
                + "&redirect_uri=" + config.getRedirectUri()
                + "&response_type=code"
                + "&scope=" + config.getScopes().replace(",", "%20")
                + "&state=" + state
                + "&nonce=" + nonce
                + "&code_challenge=" + codeChallenge
                + "&code_challenge_method=S256";
    }

    public JsonNode exchangeCodeForTokens(String code, String codeVerifier) {
        String body = "grant_type=authorization_code"
                + "&code=" + code
                + "&client_id=" + config.getClientId()
                + "&client_secret=" + config.getClientSecret()
                + "&redirect_uri=" + config.getRedirectUri()
                + "&code_verifier=" + codeVerifier;

        return httpClient.toBlocking().retrieve(
                HttpRequest.POST(getTokenEndpoint(), body)
                        .contentType(MediaType.APPLICATION_FORM_URLENCODED),
                JsonNode.class);
    }

    public JsonNode refreshToken(String refreshToken) {
        String body = "grant_type=refresh_token"
                + "&refresh_token=" + refreshToken
                + "&client_id=" + config.getClientId()
                + "&client_secret=" + config.getClientSecret();

        return httpClient.toBlocking().retrieve(
                HttpRequest.POST(getTokenEndpoint(), body)
                        .contentType(MediaType.APPLICATION_FORM_URLENCODED),
                JsonNode.class);
    }

    public JsonNode getUserInfo(String accessToken) {
        return httpClient.toBlocking().retrieve(
                HttpRequest.GET(getUserInfoEndpoint())
                        .bearerAuth(accessToken),
                JsonNode.class);
    }

    public String buildLogoutUrl(String postLogoutUri) {
        return getEndSessionEndpoint() + "?post_logout_redirect_uri=" + postLogoutUri;
    }
}
```

### Auth Controller

```java
package {{basePackage}}.auth;

import {{basePackage}}.config.ApptorAuthConfig;
import com.fasterxml.jackson.databind.JsonNode;
import io.micronaut.http.HttpResponse;
import io.micronaut.http.annotation.Controller;
import io.micronaut.http.annotation.Get;
import io.micronaut.http.annotation.QueryValue;
import io.micronaut.security.annotation.Secured;
import io.micronaut.security.rules.SecurityRule;
import io.micronaut.session.Session;

import java.net.URI;

@Controller("/auth")
@Secured(SecurityRule.IS_ANONYMOUS)
public class AuthController {

    private final ApptorOidcClient oidcClient;
    private final ApptorAuthConfig config;

    public AuthController(ApptorOidcClient oidcClient, ApptorAuthConfig config) {
        this.oidcClient = oidcClient;
        this.config = config;
    }

    @Get("/login")
    public HttpResponse<?> login(Session session) {
        String state = PkceUtil.generateSecureRandom();
        String nonce = PkceUtil.generateSecureRandom();
        String codeVerifier = PkceUtil.generateCodeVerifier();
        String codeChallenge = PkceUtil.generateCodeChallenge(codeVerifier);

        session.put("oauth_state", state);
        session.put("oauth_nonce", nonce);
        session.put("pkce_verifier", codeVerifier);

        String authUrl = oidcClient.buildAuthorizationUrl(state, codeChallenge, nonce);
        return HttpResponse.redirect(URI.create(authUrl));
    }

    @Get("/callback")
    public HttpResponse<?> callback(@QueryValue String code, @QueryValue String state, Session session) {
        String savedState = session.get("oauth_state", String.class).orElse(null);
        if (savedState == null || !savedState.equals(state)) {
            return HttpResponse.unauthorized();
        }

        String codeVerifier = session.get("pkce_verifier", String.class).orElse(null);
        if (codeVerifier == null) {
            return HttpResponse.unauthorized();
        }

        JsonNode tokens = oidcClient.exchangeCodeForTokens(code, codeVerifier);

        session.put("access_token", tokens.get("access_token").asText());
        session.put("id_token", tokens.get("id_token").asText());
        if (tokens.has("refresh_token")) {
            session.put("refresh_token", tokens.get("refresh_token").asText());
        }

        session.remove("oauth_state");
        session.remove("oauth_nonce");
        session.remove("pkce_verifier");

        return HttpResponse.redirect(URI.create(config.getPostLoginUri()));
    }

    @Get("/refresh")
    public HttpResponse<?> refresh(Session session) {
        String refreshToken = session.get("refresh_token", String.class).orElse(null);
        if (refreshToken == null) {
            return HttpResponse.redirect(URI.create("/auth/login"));
        }

        JsonNode tokens = oidcClient.refreshToken(refreshToken);
        session.put("access_token", tokens.get("access_token").asText());
        if (tokens.has("refresh_token")) {
            session.put("refresh_token", tokens.get("refresh_token").asText());
        }

        return HttpResponse.redirect(URI.create(config.getPostLoginUri()));
    }

    @Get("/logout")
    public HttpResponse<?> logout(Session session) {
        session.clear();
        String logoutUrl = oidcClient.buildLogoutUrl(config.getPostLogoutUri());
        return HttpResponse.redirect(URI.create(logoutUrl));
    }
}
```

### PKCE Utility

```java
package {{basePackage}}.auth;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.Base64;

public final class PkceUtil {
    private static final SecureRandom RANDOM = new SecureRandom();

    private PkceUtil() {}

    public static String generateCodeVerifier() {
        byte[] bytes = new byte[64];
        RANDOM.nextBytes(bytes);
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
    }

    public static String generateCodeChallenge(String codeVerifier) {
        try {
            byte[] hash = MessageDigest.getInstance("SHA-256")
                    .digest(codeVerifier.getBytes(StandardCharsets.US_ASCII));
            return Base64.getUrlEncoder().withoutPadding().encodeToString(hash);
        } catch (Exception e) {
            throw new RuntimeException("PKCE challenge generation failed", e);
        }
    }

    public static String generateSecureRandom() {
        byte[] bytes = new byte[32];
        RANDOM.nextBytes(bytes);
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
    }
}
```

### JWT Security Filter

```java
package {{basePackage}}.auth;

import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.jwk.source.RemoteJWKSet;
import com.nimbusds.jose.proc.JWSVerificationKeySelector;
import com.nimbusds.jose.proc.SecurityContext;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.proc.DefaultJWTProcessor;
import io.micronaut.http.*;
import io.micronaut.http.annotation.Filter;
import io.micronaut.http.filter.HttpServerFilter;
import io.micronaut.http.filter.ServerFilterChain;
import io.micronaut.session.Session;
import io.micronaut.session.SessionStore;
import org.reactivestreams.Publisher;
import reactor.core.publisher.Flux;

import java.net.URL;
import java.util.Set;

@Filter("/**")
public class ApptorSecurityFilter implements HttpServerFilter {

    private static final Set<String> PUBLIC_PATHS = Set.of(
            "/auth/", "/health", "/public", "/favicon.ico"
    );

    private final ApptorOidcClient oidcClient;
    private DefaultJWTProcessor<SecurityContext> jwtProcessor;

    public ApptorSecurityFilter(ApptorOidcClient oidcClient) {
        this.oidcClient = oidcClient;
        initJwtProcessor();
    }

    private void initJwtProcessor() {
        try {
            var keySource = new RemoteJWKSet<SecurityContext>(new URL(oidcClient.getJwksUri()));
            var keySelector = new JWSVerificationKeySelector<>(JWSAlgorithm.RS256, keySource);
            jwtProcessor = new DefaultJWTProcessor<>();
            jwtProcessor.setJWSKeySelector(keySelector);
        } catch (Exception e) {
            throw new RuntimeException("Failed to init JWT processor", e);
        }
    }

    @Override
    public Publisher<MutableHttpResponse<?>> doFilter(HttpRequest<?> request, ServerFilterChain chain) {
        String path = request.getPath();

        if (PUBLIC_PATHS.stream().anyMatch(path::startsWith)) {
            return chain.proceed(request);
        }

        // Check Bearer token
        String authHeader = request.getHeaders().get(HttpHeaders.AUTHORIZATION);
        if (authHeader != null && authHeader.startsWith("Bearer ")) {
            try {
                JWTClaimsSet claims = jwtProcessor.process(authHeader.substring(7), null);
                request.setAttribute("user_claims", claims);
                request.setAttribute("user_id", claims.getSubject());
                return chain.proceed(request);
            } catch (Exception e) {
                return Flux.just(HttpResponse.unauthorized());
            }
        }

        // Check session
        // (session-based validation depends on your session setup)

        return Flux.just(HttpResponse.redirect(java.net.URI.create("/auth/login")));
    }
}

---

## Admin API Client

### application.yml (add admin credentials)

```yaml
apptor:
  auth:
    realm-url: ${APPTOR_REALM_URL}
    client-id: ${APPTOR_CLIENT_ID}
    client-secret: ${APPTOR_CLIENT_SECRET}
    redirect-uri: ${APP_BASE_URL}/auth/callback
    scopes: openid,email,profile
    post-login-uri: /dashboard
    post-logout-uri: /
  admin:
    access-key-id: ${APPTOR_ADMIN_ACCESS_KEY_ID}
    access-key-secret: ${APPTOR_ADMIN_ACCESS_KEY_SECRET}
```

### Admin Config Properties

```java
package {{basePackage}}.config;

import io.micronaut.context.annotation.ConfigurationProperties;

@ConfigurationProperties("apptor.admin")
public class ApptorAdminConfig {
    private String accessKeyId;
    private String accessKeySecret;

    public String getAccessKeyId() { return accessKeyId; }
    public void setAccessKeyId(String accessKeyId) { this.accessKeyId = accessKeyId; }
    public String getAccessKeySecret() { return accessKeySecret; }
    public void setAccessKeySecret(String accessKeySecret) { this.accessKeySecret = accessKeySecret; }
}
```

### ApptorAdminClient (@Singleton, Java HttpClient)

```java
package {{basePackage}}.admin;

import {{basePackage}}.config.ApptorAdminConfig;
import {{basePackage}}.config.ApptorAuthConfig;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.inject.Singleton;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Instant;
import java.util.Map;

/**
 * Admin API client for apptorID user management (Micronaut / Java HttpClient).
 *
 * Acquires an admin token via client_credentials grant using access_key_id /
 * access_key_secret, caches it, and refreshes 60 seconds before expiry.
 *
 * Token endpoint:
 *   POST {realmBaseUrl}/oidc/token
 *   Content-Type: application/x-www-form-urlencoded
 *   grant_type=client_credentials&access_key_id=...&access_key_secret=...
 */
@Singleton
public class ApptorAdminClient {
    private static final Logger LOG = LoggerFactory.getLogger(ApptorAdminClient.class);

    private final ApptorAuthConfig authConfig;
    private final ApptorAdminConfig adminConfig;
    private final HttpClient httpClient;
    private final ObjectMapper objectMapper;

    private String cachedToken = null;
    private Instant tokenExpiresAt = Instant.EPOCH;

    public ApptorAdminClient(ApptorAuthConfig authConfig, ApptorAdminConfig adminConfig) {
        this.authConfig = authConfig;
        this.adminConfig = adminConfig;
        this.httpClient = HttpClient.newHttpClient();
        this.objectMapper = new ObjectMapper();
    }

    /**
     * Returns a valid admin token, acquiring a new one if expired or absent.
     * Synchronized to prevent concurrent token refreshes under load.
     */
    private synchronized String getAdminToken() throws Exception {
        if (cachedToken != null && Instant.now().isBefore(tokenExpiresAt.minusSeconds(60))) {
            return cachedToken;
        }

        String body = "grant_type=client_credentials"
                + "&access_key_id=" + adminConfig.getAccessKeyId()
                + "&access_key_secret=" + adminConfig.getAccessKeySecret();

        HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create(authConfig.getRealmBaseUrl() + "/oidc/token"))
                .header("Content-Type", "application/x-www-form-urlencoded")
                .POST(HttpRequest.BodyPublishers.ofString(body))
                .build();

        HttpResponse<String> response = httpClient.send(request, HttpResponse.BodyHandlers.ofString());
        if (response.statusCode() < 200 || response.statusCode() >= 300) {
            throw new RuntimeException("Failed to acquire admin token, status: " + response.statusCode());
        }

        JsonNode json = objectMapper.readTree(response.body());
        cachedToken = json.get("access_token").asText();
        long expiresIn = json.has("expires_in") ? json.get("expires_in").asLong() : 3600L;
        tokenExpiresAt = Instant.now().plusSeconds(expiresIn);
        LOG.debug("Admin token acquired, expires in {}s", expiresIn);
        return cachedToken;
    }

    private JsonNode adminGet(String path) throws Exception {
        HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create(authConfig.getRealmBaseUrl() + path))
                .header("Authorization", "Bearer " + getAdminToken())
                .GET()
                .build();
        HttpResponse<String> response = httpClient.send(request, HttpResponse.BodyHandlers.ofString());
        return objectMapper.readTree(response.body());
    }

    private JsonNode adminPost(String path, Object body) throws Exception {
        String json = objectMapper.writeValueAsString(body);
        HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create(authConfig.getRealmBaseUrl() + path))
                .header("Authorization", "Bearer " + getAdminToken())
                .header("Content-Type", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString(json))
                .build();
        HttpResponse<String> response = httpClient.send(request, HttpResponse.BodyHandlers.ofString());
        return objectMapper.readTree(response.body());
    }

    private JsonNode adminPut(String path, Object body) throws Exception {
        String json = objectMapper.writeValueAsString(body);
        HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create(authConfig.getRealmBaseUrl() + path))
                .header("Authorization", "Bearer " + getAdminToken())
                .header("Content-Type", "application/json")
                .PUT(HttpRequest.BodyPublishers.ofString(json))
                .build();
        HttpResponse<String> response = httpClient.send(request, HttpResponse.BodyHandlers.ofString());
        return objectMapper.readTree(response.body());
    }

    private void adminPatch(String path) throws Exception {
        HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create(authConfig.getRealmBaseUrl() + path))
                .header("Authorization", "Bearer " + getAdminToken())
                .method("PATCH", HttpRequest.BodyPublishers.noBody())
                .build();
        httpClient.send(request, HttpResponse.BodyHandlers.ofString());
    }

    private void adminDelete(String path) throws Exception {
        HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create(authConfig.getRealmBaseUrl() + path))
                .header("Authorization", "Bearer " + getAdminToken())
                .DELETE()
                .build();
        httpClient.send(request, HttpResponse.BodyHandlers.ofString());
    }

    /** Create a user in a realm. User map must include orgRefId. */
    public JsonNode createUser(String realmId, Map<String, Object> user) throws Exception {
        return adminPost("/realms/" + realmId + "/users", user);
    }

    /** List users in a realm. */
    public JsonNode listUsers(String realmId, int page, int size, String search) throws Exception {
        String query = "?page=" + page + "&size=" + size
                + (search != null && !search.isBlank() ? "&search=" + search : "");
        return adminGet("/realms/" + realmId + "/users" + query);
    }

    /** Get a single user by userId. */
    public JsonNode getUser(String realmId, String userId) throws Exception {
        return adminGet("/realms/" + realmId + "/users/" + userId);
    }

    /** Update user profile fields. */
    public JsonNode updateUser(String realmId, String userId, Map<String, Object> updates) throws Exception {
        return adminPut("/realms/" + realmId + "/users/" + userId, updates);
    }

    /** Disable (deactivate) a user account. */
    public void disableUser(String realmId, String userId) throws Exception {
        adminPatch("/realms/" + realmId + "/users/" + userId + "/disable");
    }

    /** Enable (reactivate) a user account. */
    public void enableUser(String realmId, String userId) throws Exception {
        adminPatch("/realms/" + realmId + "/users/" + userId + "/enable");
    }

    /** Permanently delete a user. */
    public void deleteUser(String realmId, String userId) throws Exception {
        adminDelete("/realms/" + realmId + "/users/" + userId);
    }

    /** Trigger forgot-password email for the user. */
    public JsonNode forgotPassword(String realmId, String email) throws Exception {
        return adminPost("/realms/" + realmId + "/users/forgot-password", Map.of("email", email));
    }

    /** Directly set a user's password (admin override). */
    public JsonNode setPassword(String realmId, String userId, String newPassword, boolean temporary) throws Exception {
        return adminPost("/realms/" + realmId + "/users/" + userId + "/set-password",
                Map.of("password", newPassword, "temporary", temporary));
    }
}
```

### UserManagementController (Micronaut @Controller)

```java
package {{basePackage}}.admin;

import com.fasterxml.jackson.databind.JsonNode;
import io.micronaut.http.HttpResponse;
import io.micronaut.http.HttpStatus;
import io.micronaut.http.annotation.*;
import io.micronaut.security.annotation.Secured;
import io.micronaut.security.rules.SecurityRule;

import java.util.Map;

/**
 * REST endpoints for admin user management.
 * Mounted at /admin/realms/{realmId}/users.
 * Secure these routes via Micronaut Security or your JWT filter.
 */
@Controller("/admin/realms/{realmId}/users")
@Secured(SecurityRule.IS_AUTHENTICATED)
public class UserManagementController {

    private final ApptorAdminClient adminClient;

    public UserManagementController(ApptorAdminClient adminClient) {
        this.adminClient = adminClient;
    }

    @Get
    public HttpResponse<JsonNode> listUsers(
            @PathVariable String realmId,
            @QueryValue(defaultValue = "0") int page,
            @QueryValue(defaultValue = "20") int size,
            @QueryValue(defaultValue = "") String search) throws Exception {
        return HttpResponse.ok(adminClient.listUsers(realmId, page, size, search.isBlank() ? null : search));
    }

    @Post
    public HttpResponse<JsonNode> createUser(
            @PathVariable String realmId,
            @Body Map<String, Object> user) throws Exception {
        if (!user.containsKey("email") || !user.containsKey("orgRefId")) {
            return HttpResponse.badRequest();
        }
        return HttpResponse.status(HttpStatus.CREATED).body(adminClient.createUser(realmId, user));
    }

    @Get("/{userId}")
    public HttpResponse<JsonNode> getUser(
            @PathVariable String realmId,
            @PathVariable String userId) throws Exception {
        return HttpResponse.ok(adminClient.getUser(realmId, userId));
    }

    @Put("/{userId}")
    public HttpResponse<JsonNode> updateUser(
            @PathVariable String realmId,
            @PathVariable String userId,
            @Body Map<String, Object> updates) throws Exception {
        return HttpResponse.ok(adminClient.updateUser(realmId, userId, updates));
    }

    @Patch("/{userId}/disable")
    public HttpResponse<Void> disableUser(
            @PathVariable String realmId,
            @PathVariable String userId) throws Exception {
        adminClient.disableUser(realmId, userId);
        return HttpResponse.noContent();
    }

    @Patch("/{userId}/enable")
    public HttpResponse<Void> enableUser(
            @PathVariable String realmId,
            @PathVariable String userId) throws Exception {
        adminClient.enableUser(realmId, userId);
        return HttpResponse.noContent();
    }

    @Delete("/{userId}")
    public HttpResponse<Void> deleteUser(
            @PathVariable String realmId,
            @PathVariable String userId) throws Exception {
        adminClient.deleteUser(realmId, userId);
        return HttpResponse.noContent();
    }

    @Post("/{userId}/set-password")
    public HttpResponse<Void> setPassword(
            @PathVariable String realmId,
            @PathVariable String userId,
            @Body Map<String, Object> body) throws Exception {
        String password = (String) body.get("password");
        boolean temporary = Boolean.TRUE.equals(body.get("temporary"));
        if (password == null || password.isBlank()) {
            return HttpResponse.badRequest();
        }
        adminClient.setPassword(realmId, userId, password, temporary);
        return HttpResponse.noContent();
    }
}
```
