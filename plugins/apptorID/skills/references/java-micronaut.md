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
```
