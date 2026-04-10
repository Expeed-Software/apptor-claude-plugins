# Java Spring Boot — apptorID Integration Templates

## Table of Contents
1. [Dependencies](#dependencies)
2. [Configuration](#configuration)
3. [OAuth2 Client Service](#oauth2-client-service)
4. [Auth Controller](#auth-controller)
5. [JWT Validation Filter](#jwt-validation-filter)
6. [PKCE Utility](#pkce-utility)
7. [Client-Hosted Login (Pre-Authorize Flow)](#client-hosted-login)
8. [Multi-Tenant Tenant Resolver](#multi-tenant-tenant-resolver)

---

## Dependencies

Add to `pom.xml`:
```xml
<dependencies>
    <!-- HTTP client for apptorID communication -->
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-web</artifactId>
    </dependency>
    <!-- JWT validation -->
    <dependency>
        <groupId>com.nimbusds</groupId>
        <artifactId>nimbus-jose-jwt</artifactId>
        <version>9.37</version>
    </dependency>
    <!-- HTTP client -->
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-webflux</artifactId>
    </dependency>
    <!-- Session management (optional, for server-side sessions) -->
    <dependency>
        <groupId>org.springframework.session</groupId>
        <artifactId>spring-session-core</artifactId>
    </dependency>
</dependencies>
```

Or for Gradle (`build.gradle`):
```groovy
dependencies {
    implementation 'org.springframework.boot:spring-boot-starter-web'
    implementation 'org.springframework.boot:spring-boot-starter-webflux'
    implementation 'com.nimbusds:nimbus-jose-jwt:9.37'
    implementation 'org.springframework.session:spring-session-core'
}
```

---

## Configuration

### application.yml (Single-Tenant)
```yaml
apptor:
  auth:
    realm-url: https://${APPTOR_REALM_URL}
    client-id: ${APPTOR_CLIENT_ID}
    client-secret: ${APPTOR_CLIENT_SECRET}
    redirect-uri: ${APP_BASE_URL}/auth/callback
    post-login-uri: /dashboard
    post-logout-uri: /
    scopes: openid,email,profile
```

### Configuration Properties Class
```java
package {{basePackage}}.config;

import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

@Component
@ConfigurationProperties(prefix = "apptor.auth")
public class ApptorAuthProperties {
    private String realmUrl;
    private String clientId;
    private String clientSecret;
    private String redirectUri;
    private String postLoginUri = "/dashboard";
    private String postLogoutUri = "/";
    private String scopes = "openid,email,profile";

    // Standard getters and setters
    public String getRealmUrl() { return realmUrl; }
    public void setRealmUrl(String realmUrl) { this.realmUrl = realmUrl; }
    public String getClientId() { return clientId; }
    public void setClientId(String clientId) { this.clientId = clientId; }
    public String getClientSecret() { return clientSecret; }
    public void setClientSecret(String clientSecret) { this.clientSecret = clientSecret; }
    public String getRedirectUri() { return redirectUri; }
    public void setRedirectUri(String redirectUri) { this.redirectUri = redirectUri; }
    public String getPostLoginUri() { return postLoginUri; }
    public void setPostLoginUri(String postLoginUri) { this.postLoginUri = postLoginUri; }
    public String getPostLogoutUri() { return postLogoutUri; }
    public void setPostLogoutUri(String postLogoutUri) { this.postLogoutUri = postLogoutUri; }
    public String getScopes() { return scopes; }
    public void setScopes(String scopes) { this.scopes = scopes; }

    public String getDiscoveryUrl() {
        String base = realmUrl.startsWith("http") ? realmUrl : "https://" + realmUrl;
        return base + "/.well-known/openid-configuration";
    }
}
```

---

## OAuth2 Client Service

```java
package {{basePackage}}.auth;

import {{basePackage}}.config.ApptorAuthProperties;
import com.fasterxml.jackson.databind.JsonNode;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.*;
import org.springframework.stereotype.Service;
import org.springframework.util.LinkedMultiValueMap;
import org.springframework.util.MultiValueMap;
import org.springframework.web.reactive.function.BodyInserters;
import org.springframework.web.reactive.function.client.WebClient;

import jakarta.annotation.PostConstruct;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

@Service
public class ApptorOidcClient {
    private static final Logger log = LoggerFactory.getLogger(ApptorOidcClient.class);

    private final ApptorAuthProperties properties;
    private final WebClient webClient;
    private final Map<String, Object> discoveryCache = new ConcurrentHashMap<>();

    public ApptorOidcClient(ApptorAuthProperties properties, WebClient.Builder webClientBuilder) {
        this.properties = properties;
        this.webClient = webClientBuilder.build();
    }

    @PostConstruct
    public void init() {
        fetchDiscovery();
    }

    /**
     * Fetch and cache the OIDC discovery document from the realm.
     */
    public void fetchDiscovery() {
        try {
            JsonNode discovery = webClient.get()
                    .uri(properties.getDiscoveryUrl())
                    .retrieve()
                    .bodyToMono(JsonNode.class)
                    .block();

            if (discovery != null) {
                discoveryCache.put("authorization_endpoint", discovery.get("authorization_endpoint").asText());
                discoveryCache.put("token_endpoint", discovery.get("token_endpoint").asText());
                discoveryCache.put("userinfo_endpoint", discovery.get("userinfo_endpoint").asText());
                discoveryCache.put("jwks_uri", discovery.get("jwks_uri").asText());
                discoveryCache.put("end_session_endpoint", discovery.get("end_session_endpoint").asText());
                discoveryCache.put("issuer", discovery.get("issuer").asText());
                log.info("apptorID discovery loaded from {}", properties.getDiscoveryUrl());
            }
        } catch (Exception e) {
            log.error("Failed to fetch apptorID discovery document", e);
            throw new RuntimeException("Cannot connect to apptorID at " + properties.getDiscoveryUrl(), e);
        }
    }

    public String getAuthorizationEndpoint() {
        return (String) discoveryCache.get("authorization_endpoint");
    }

    public String getTokenEndpoint() {
        return (String) discoveryCache.get("token_endpoint");
    }

    public String getUserInfoEndpoint() {
        return (String) discoveryCache.get("userinfo_endpoint");
    }

    public String getJwksUri() {
        return (String) discoveryCache.get("jwks_uri");
    }

    public String getEndSessionEndpoint() {
        return (String) discoveryCache.get("end_session_endpoint");
    }

    public String getIssuer() {
        return (String) discoveryCache.get("issuer");
    }

    /**
     * Build the authorization URL for redirecting the user to apptorID login.
     * Backend apps: no PKCE needed — client_secret authenticates the token exchange.
     */
    public String buildAuthorizationUrl(String state, String nonce) {
        return getAuthorizationEndpoint()
                + "?client_id=" + properties.getClientId()
                + "&redirect_uri=" + properties.getRedirectUri()
                + "&response_type=code"
                + "&scope=" + properties.getScopes().replace(",", "%20")
                + "&state=" + state
                + "&nonce=" + nonce;
    }

    /**
     * Exchange an authorization code for tokens using client_secret (backend flow).
     * client_secret comes from application.yml / env var — never exposed to browser.
     */
    public JsonNode exchangeCodeForTokens(String code) {
        MultiValueMap<String, String> formData = new LinkedMultiValueMap<>();
        formData.add("grant_type", "authorization_code");
        formData.add("code", code);
        formData.add("client_id", properties.getClientId());
        formData.add("client_secret", properties.getClientSecret());
        formData.add("redirect_uri", properties.getRedirectUri());

        return webClient.post()
                .uri(getTokenEndpoint())
                .contentType(MediaType.APPLICATION_FORM_URLENCODED)
                .body(BodyInserters.fromFormData(formData))
                .retrieve()
                .bodyToMono(JsonNode.class)
                .block();
    }

    /**
     * Refresh an access token using a refresh token.
     */
    public JsonNode refreshToken(String refreshToken) {
        MultiValueMap<String, String> formData = new LinkedMultiValueMap<>();
        formData.add("grant_type", "refresh_token");
        formData.add("refresh_token", refreshToken);
        formData.add("client_id", properties.getClientId());
        formData.add("client_secret", properties.getClientSecret());

        return webClient.post()
                .uri(getTokenEndpoint())
                .contentType(MediaType.APPLICATION_FORM_URLENCODED)
                .body(BodyInserters.fromFormData(formData))
                .retrieve()
                .bodyToMono(JsonNode.class)
                .block();
    }

    /**
     * Fetch user info using an access token.
     */
    public JsonNode getUserInfo(String accessToken) {
        return webClient.get()
                .uri(getUserInfoEndpoint())
                .headers(h -> h.setBearerAuth(accessToken))
                .retrieve()
                .bodyToMono(JsonNode.class)
                .block();
    }

    /**
     * Build the logout URL.
     */
    public String buildLogoutUrl(String postLogoutRedirectUri) {
        return getEndSessionEndpoint() + "?post_logout_redirect_uri=" + postLogoutRedirectUri;
    }
}
```

---

## Auth Controller

```java
package {{basePackage}}.auth;

import {{basePackage}}.config.ApptorAuthProperties;
import com.fasterxml.jackson.databind.JsonNode;
import jakarta.servlet.http.HttpSession;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Controller;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.servlet.view.RedirectView;

import java.security.SecureRandom;
import java.util.Base64;

@Controller
@RequestMapping("/auth")
public class AuthController {

    private final ApptorOidcClient oidcClient;
    private final ApptorAuthProperties properties;

    public AuthController(ApptorOidcClient oidcClient, ApptorAuthProperties properties) {
        this.oidcClient = oidcClient;
        this.properties = properties;
    }

    /**
     * Initiates the OAuth2 Authorization Code flow.
     * Backend apps use client_secret for token exchange — no PKCE needed.
     * Redirects the user to apptorID's authorization endpoint.
     */
    @GetMapping("/login")
    public RedirectView login(HttpSession session) {
        String state = generateSecureRandom();
        String nonce = generateSecureRandom();

        // Store state in session for validation on callback
        session.setAttribute("oauth_state", state);
        session.setAttribute("oauth_nonce", nonce);

        String authUrl = oidcClient.buildAuthorizationUrl(state, nonce);
        return new RedirectView(authUrl);
    }

    /**
     * Handles the OAuth2 callback. Receives ?code=xxx&state=xxx,
     * validates state, exchanges code for tokens using client_id + client_secret
     * (from application.yml / env var), stores tokens in session,
     * and redirects to dashboard.
     */
    @GetMapping("/callback")
    public RedirectView callback(
            @RequestParam("code") String code,
            @RequestParam("state") String state,
            HttpSession session
    ) {
        // 1. Validate state to prevent CSRF
        String savedState = (String) session.getAttribute("oauth_state");
        if (savedState == null || !savedState.equals(state)) {
            throw new SecurityException("Invalid OAuth2 state parameter — possible CSRF attack");
        }

        // 2. Exchange code for tokens using client_secret on the backend
        JsonNode tokens = oidcClient.exchangeCodeForTokens(code);

        // 3. Store tokens in session
        session.setAttribute("access_token", tokens.get("access_token").asText());
        session.setAttribute("id_token", tokens.get("id_token").asText());
        if (tokens.has("refresh_token")) {
            session.setAttribute("refresh_token", tokens.get("refresh_token").asText());
        }

        // 4. Clean up state
        session.removeAttribute("oauth_state");
        session.removeAttribute("oauth_nonce");

        // 5. Redirect to dashboard
        return new RedirectView(properties.getPostLoginUri());
    }

    /**
     * Refreshes the access token using the stored refresh token.
     */
    @GetMapping("/refresh")
    public RedirectView refresh(HttpSession session) {
        String refreshToken = (String) session.getAttribute("refresh_token");
        if (refreshToken == null) {
            return new RedirectView("/auth/login");
        }

        JsonNode tokens = oidcClient.refreshToken(refreshToken);
        session.setAttribute("access_token", tokens.get("access_token").asText());
        if (tokens.has("refresh_token")) {
            session.setAttribute("refresh_token", tokens.get("refresh_token").asText());
        }

        String referer = (String) session.getAttribute("last_page");
        return new RedirectView(referer != null ? referer : properties.getPostLoginUri());
    }

    /**
     * Logs the user out — clears session and redirects to apptorID logout.
     */
    @GetMapping("/logout")
    public RedirectView logout(HttpSession session) {
        session.invalidate();
        String logoutUrl = oidcClient.buildLogoutUrl(properties.getPostLogoutUri());
        return new RedirectView(logoutUrl);
    }

    private String generateSecureRandom() {
        byte[] bytes = new byte[32];
        new SecureRandom().nextBytes(bytes);
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
    }
}
```

---

## JWT Validation Filter

```java
package {{basePackage}}.auth;

import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.jwk.source.JWKSource;
import com.nimbusds.jose.jwk.source.RemoteJWKSet;
import com.nimbusds.jose.proc.JWSKeySelector;
import com.nimbusds.jose.proc.JWSVerificationKeySelector;
import com.nimbusds.jose.proc.SecurityContext;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.proc.ConfigurableJWTProcessor;
import com.nimbusds.jwt.proc.DefaultJWTProcessor;
import jakarta.servlet.*;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import jakarta.servlet.http.HttpSession;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;

import java.io.IOException;
import java.net.URL;
import java.util.List;
import java.util.Set;

@Component
@Order(1)
public class ApptorAuthFilter implements Filter {
    private static final Logger log = LoggerFactory.getLogger(ApptorAuthFilter.class);

    private final ApptorOidcClient oidcClient;
    private ConfigurableJWTProcessor<SecurityContext> jwtProcessor;

    // Paths that don't require authentication
    private static final Set<String> PUBLIC_PATHS = Set.of(
            "/auth/login", "/auth/callback", "/auth/logout",
            "/health", "/actuator", "/public", "/favicon.ico"
    );

    public ApptorAuthFilter(ApptorOidcClient oidcClient) {
        this.oidcClient = oidcClient;
    }

    @Override
    public void init(FilterConfig filterConfig) throws ServletException {
        try {
            JWKSource<SecurityContext> keySource = new RemoteJWKSet<>(new URL(oidcClient.getJwksUri()));
            JWSKeySelector<SecurityContext> keySelector = new JWSVerificationKeySelector<>(JWSAlgorithm.RS256, keySource);
            jwtProcessor = new DefaultJWTProcessor<>();
            jwtProcessor.setJWSKeySelector(keySelector);
            log.info("apptorID JWT processor initialized with JWKS from {}", oidcClient.getJwksUri());
        } catch (Exception e) {
            log.error("Failed to initialize JWT processor", e);
            throw new ServletException("Cannot initialize apptorID JWT validation", e);
        }
    }

    @Override
    public void doFilter(ServletRequest request, ServletResponse response, FilterChain chain)
            throws IOException, ServletException {
        HttpServletRequest httpRequest = (HttpServletRequest) request;
        HttpServletResponse httpResponse = (HttpServletResponse) response;
        String path = httpRequest.getRequestURI();

        // Skip auth for public paths
        if (PUBLIC_PATHS.stream().anyMatch(path::startsWith)) {
            chain.doFilter(request, response);
            return;
        }

        // Check for Bearer token in Authorization header (API calls)
        String authHeader = httpRequest.getHeader("Authorization");
        if (authHeader != null && authHeader.startsWith("Bearer ")) {
            String token = authHeader.substring(7);
            try {
                JWTClaimsSet claims = jwtProcessor.process(token, null);
                httpRequest.setAttribute("user_claims", claims);
                httpRequest.setAttribute("user_id", claims.getSubject());
                if (claims.getClaim("roles") != null) {
                    httpRequest.setAttribute("user_roles", claims.getClaim("roles"));
                }
                chain.doFilter(request, response);
                return;
            } catch (Exception e) {
                log.warn("Invalid Bearer token: {}", e.getMessage());
                httpResponse.setStatus(HttpServletResponse.SC_UNAUTHORIZED);
                httpResponse.getWriter().write("{\"error\":\"invalid_token\",\"message\":\"" + e.getMessage() + "\"}");
                return;
            }
        }

        // Check for session-based auth (web app)
        HttpSession session = httpRequest.getSession(false);
        if (session != null && session.getAttribute("access_token") != null) {
            String accessToken = (String) session.getAttribute("access_token");
            try {
                JWTClaimsSet claims = jwtProcessor.process(accessToken, null);
                httpRequest.setAttribute("user_claims", claims);
                httpRequest.setAttribute("user_id", claims.getSubject());
                session.setAttribute("last_page", path);
                chain.doFilter(request, response);
                return;
            } catch (Exception e) {
                // Token expired — try refresh
                log.debug("Session token expired, attempting refresh");
                session.removeAttribute("access_token");
                httpResponse.sendRedirect("/auth/refresh");
                return;
            }
        }

        // Not authenticated — redirect to login
        httpResponse.sendRedirect("/auth/login");
    }
}
```

---

## PKCE Utility

```java
package {{basePackage}}.auth;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.Base64;

public final class PkceUtil {
    private static final SecureRandom RANDOM = new SecureRandom();

    private PkceUtil() {}

    /**
     * Generate a cryptographically random code verifier (43-128 chars).
     */
    public static String generateCodeVerifier() {
        byte[] bytes = new byte[64];
        RANDOM.nextBytes(bytes);
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
    }

    /**
     * Generate code challenge from verifier using S256 method.
     */
    public static String generateCodeChallenge(String codeVerifier) {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            byte[] hash = digest.digest(codeVerifier.getBytes(StandardCharsets.US_ASCII));
            return Base64.getUrlEncoder().withoutPadding().encodeToString(hash);
        } catch (Exception e) {
            throw new RuntimeException("Failed to generate PKCE code challenge", e);
        }
    }
}
```

---

## Client-Hosted Login

If the developer hosts their own login page and uses the pre-authorize flow:

```java
package {{basePackage}}.auth;

import {{basePackage}}.config.ApptorAuthProperties;
import com.fasterxml.jackson.databind.JsonNode;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.util.LinkedMultiValueMap;
import org.springframework.util.MultiValueMap;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.reactive.function.BodyInserters;
import org.springframework.web.reactive.function.client.WebClient;

import jakarta.servlet.http.HttpSession;
import java.util.Map;

@RestController
@RequestMapping("/auth")
public class ClientHostedLoginController {

    private final ApptorAuthProperties properties;
    private final ApptorOidcClient oidcClient;
    private final WebClient webClient;

    public ClientHostedLoginController(ApptorAuthProperties properties,
                                        ApptorOidcClient oidcClient,
                                        WebClient.Builder webClientBuilder) {
        this.properties = properties;
        this.oidcClient = oidcClient;
        this.webClient = webClientBuilder.build();
    }

    /**
     * Step 1: Initiate the auth flow — get a request_id from apptorID.
     * The frontend calls this, then renders the login form with the request_id.
     */
    @GetMapping("/init")
    public ResponseEntity<Map<String, String>> initLogin(HttpSession session) {
        String state = PkceUtil.generateCodeVerifier().substring(0, 32);
        String codeVerifier = PkceUtil.generateCodeVerifier();
        String codeChallenge = PkceUtil.generateCodeChallenge(codeVerifier);

        session.setAttribute("oauth_state", state);
        session.setAttribute("pkce_verifier", codeVerifier);

        // Build the auth URL that will return a request_id via redirect
        String authUrl = oidcClient.buildAuthorizationUrl(state, codeChallenge, state)
                + "&login_uri=" + properties.getRedirectUri().replace("/callback", "/login-page");

        return ResponseEntity.ok(Map.of("authUrl", authUrl));
    }

    /**
     * Step 2: User submits credentials. We call pre-authorize to validate them.
     */
    @PostMapping("/pre-authorize")
    public ResponseEntity<?> preAuthorize(@RequestBody Map<String, String> credentials,
                                           @RequestParam String requestId,
                                           HttpSession session) {
        MultiValueMap<String, String> formData = new LinkedMultiValueMap<>();
        formData.add("username", credentials.get("username"));
        formData.add("password", credentials.get("password"));
        formData.add("request_id", requestId);

        String realmBase = properties.getRealmUrl().startsWith("http")
                ? properties.getRealmUrl()
                : "https://" + properties.getRealmUrl();

        JsonNode response = webClient.post()
                .uri(realmBase + "/oidc/pre-authorize")
                .contentType(MediaType.APPLICATION_FORM_URLENCODED)
                .body(BodyInserters.fromFormData(formData))
                .retrieve()
                .bodyToMono(JsonNode.class)
                .block();

        if (response != null && response.has("preAuthToken")) {
            // Return the exchange URL for the frontend to redirect to
            String exchangeUrl = realmBase + "/oidc/auth"
                    + "?request_id=" + requestId
                    + "&preAuthToken=" + response.get("preAuthToken").asText();
            return ResponseEntity.ok(Map.of("redirectUrl", exchangeUrl));
        }

        return ResponseEntity.badRequest().body(Map.of("error", "Authentication failed"));
    }

    /**
     * Step 3: Redirect to external IdP (Google, Microsoft).
     */
    @GetMapping("/social/{providerId}")
    public ResponseEntity<Map<String, String>> socialLogin(@PathVariable String providerId,
                                                             @RequestParam String requestId) {
        String realmBase = properties.getRealmUrl().startsWith("http")
                ? properties.getRealmUrl()
                : "https://" + properties.getRealmUrl();

        String socialUrl = realmBase + "/oidc/auth"
                + "?provider_id=" + providerId
                + "&request_id=" + requestId;

        return ResponseEntity.ok(Map.of("redirectUrl", socialUrl));
    }
}
```

---

## Multi-Tenant Tenant Resolver

If multi-tenant, add a resolver that determines the current org and loads its apptorID config:

```java
package {{basePackage}}.auth;

import {{basePackage}}.model.OrgAuthConfig;
import {{basePackage}}.repository.OrgAuthConfigRepository;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.stereotype.Component;

import java.util.Optional;

@Component
public class TenantResolver {

    private final OrgAuthConfigRepository configRepository;

    public TenantResolver(OrgAuthConfigRepository configRepository) {
        this.configRepository = configRepository;
    }

    /**
     * Resolve the current tenant's apptorID configuration from the request.
     *
     * Override this method to match your tenancy strategy:
     * - Subdomain: parse Host header (e.g., acme.app.com → "acme")
     * - Path: parse URL path (e.g., /org/acme/... → "acme")
     * - Header: read X-Tenant-ID header
     * - Session: read org_id from authenticated session
     */
    public OrgAuthConfig resolve(HttpServletRequest request) {
        // Strategy 1: Subdomain-based
        String host = request.getHeader("Host");
        if (host != null && host.contains(".")) {
            String subdomain = host.split("\\.")[0];
            Optional<OrgAuthConfig> config = configRepository.findByOrgIdentifier(subdomain);
            if (config.isPresent()) return config.get();
        }

        // Strategy 2: Header-based
        String tenantId = request.getHeader("X-Tenant-ID");
        if (tenantId != null) {
            Optional<OrgAuthConfig> config = configRepository.findByOrgId(tenantId);
            if (config.isPresent()) return config.get();
        }

        // Strategy 3: Session-based (after login)
        String orgId = (String) request.getSession(false) != null
                ? (String) request.getSession().getAttribute("org_id")
                : null;
        if (orgId != null) {
            Optional<OrgAuthConfig> config = configRepository.findByOrgId(orgId);
            if (config.isPresent()) return config.get();
        }

        throw new RuntimeException("Cannot resolve tenant from request");
    }
}
```

See `references/multitenant-db.md` for the `OrgAuthConfig` entity and repository.

---

## Admin API Client

### application.yml (add admin credentials)

```yaml
apptor:
  auth:
    realm-url: https://${APPTOR_REALM_URL}
    client-id: ${APPTOR_CLIENT_ID}
    client-secret: ${APPTOR_CLIENT_SECRET}
    redirect-uri: ${APP_BASE_URL}/auth/callback
    post-login-uri: /dashboard
    post-logout-uri: /
    scopes: openid,email,profile
  admin:
    access-key-id: ${APPTOR_ADMIN_ACCESS_KEY_ID}
    access-key-secret: ${APPTOR_ADMIN_ACCESS_KEY_SECRET}
```

### Admin Properties Class

```java
package {{basePackage}}.config;

import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

@Component
@ConfigurationProperties(prefix = "apptor.admin")
public class ApptorAdminProperties {
    private String accessKeyId;
    private String accessKeySecret;

    public String getAccessKeyId() { return accessKeyId; }
    public void setAccessKeyId(String accessKeyId) { this.accessKeyId = accessKeyId; }
    public String getAccessKeySecret() { return accessKeySecret; }
    public void setAccessKeySecret(String accessKeySecret) { this.accessKeySecret = accessKeySecret; }
}
```

### ApptorAdminClient (Spring @Service)

```java
package {{basePackage}}.admin;

import {{basePackage}}.config.ApptorAdminProperties;
import {{basePackage}}.config.ApptorAuthProperties;
import com.fasterxml.jackson.databind.JsonNode;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Service;
import org.springframework.util.LinkedMultiValueMap;
import org.springframework.util.MultiValueMap;
import org.springframework.web.reactive.function.BodyInserters;
import org.springframework.web.reactive.function.client.WebClient;

import java.time.Instant;
import java.util.Map;

/**
 * Admin API client for apptorID user management.
 *
 * Acquires an admin token via client_credentials grant using access_key_id /
 * access_key_secret, caches it, and refreshes 60 seconds before expiry.
 *
 * Token endpoint:
 *   POST {realmBaseUrl}/oidc/token
 *   Content-Type: application/x-www-form-urlencoded
 *   grant_type=client_credentials&access_key_id=...&access_key_secret=...
 */
@Service
public class ApptorAdminClient {
    private static final Logger log = LoggerFactory.getLogger(ApptorAdminClient.class);

    private final ApptorAuthProperties authProperties;
    private final ApptorAdminProperties adminProperties;
    private final WebClient webClient;

    private String cachedToken = null;
    private Instant tokenExpiresAt = Instant.EPOCH;

    public ApptorAdminClient(ApptorAuthProperties authProperties,
                              ApptorAdminProperties adminProperties,
                              WebClient.Builder webClientBuilder) {
        this.authProperties = authProperties;
        this.adminProperties = adminProperties;
        this.webClient = webClientBuilder.build();
    }

    /**
     * Returns a valid admin token, acquiring a new one if expired or absent.
     * Synchronized to prevent concurrent token refreshes under load.
     */
    private synchronized String getAdminToken() {
        if (cachedToken != null && Instant.now().isBefore(tokenExpiresAt.minusSeconds(60))) {
            return cachedToken;
        }

        String realmBase = authProperties.getRealmUrl().startsWith("http")
                ? authProperties.getRealmUrl()
                : "https://" + authProperties.getRealmUrl();

        MultiValueMap<String, String> formData = new LinkedMultiValueMap<>();
        formData.add("grant_type", "client_credentials");
        formData.add("access_key_id", adminProperties.getAccessKeyId());
        formData.add("access_key_secret", adminProperties.getAccessKeySecret());

        JsonNode response = webClient.post()
                .uri(realmBase + "/oidc/token")
                .contentType(MediaType.APPLICATION_FORM_URLENCODED)
                .body(BodyInserters.fromFormData(formData))
                .retrieve()
                .bodyToMono(JsonNode.class)
                .block();

        if (response == null || !response.has("access_token")) {
            throw new RuntimeException("Failed to acquire admin token from apptorID");
        }

        cachedToken = response.get("access_token").asText();
        long expiresIn = response.has("expires_in") ? response.get("expires_in").asLong() : 3600L;
        tokenExpiresAt = Instant.now().plusSeconds(expiresIn);
        log.debug("Admin token acquired, expires in {}s", expiresIn);
        return cachedToken;
    }

    private String realmApiBase() {
        String base = authProperties.getRealmUrl().startsWith("http")
                ? authProperties.getRealmUrl()
                : "https://" + authProperties.getRealmUrl();
        return base;
    }

    private JsonNode adminGet(String path) {
        return webClient.get()
                .uri(realmApiBase() + path)
                .headers(h -> h.setBearerAuth(getAdminToken()))
                .retrieve()
                .bodyToMono(JsonNode.class)
                .block();
    }

    private JsonNode adminPost(String path, Object body) {
        return webClient.post()
                .uri(realmApiBase() + path)
                .headers(h -> h.setBearerAuth(getAdminToken()))
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(body)
                .retrieve()
                .bodyToMono(JsonNode.class)
                .block();
    }

    private JsonNode adminPut(String path, Object body) {
        return webClient.put()
                .uri(realmApiBase() + path)
                .headers(h -> h.setBearerAuth(getAdminToken()))
                .contentType(MediaType.APPLICATION_JSON)
                .bodyValue(body)
                .retrieve()
                .bodyToMono(JsonNode.class)
                .block();
    }

    private JsonNode adminPatch(String path) {
        return webClient.patch()
                .uri(realmApiBase() + path)
                .headers(h -> h.setBearerAuth(getAdminToken()))
                .retrieve()
                .bodyToMono(JsonNode.class)
                .block();
    }

    private void adminDelete(String path) {
        webClient.delete()
                .uri(realmApiBase() + path)
                .headers(h -> h.setBearerAuth(getAdminToken()))
                .retrieve()
                .bodyToMono(Void.class)
                .block();
    }

    /** Create a user in a realm. User map must include orgRefId. */
    public JsonNode createUser(String realmId, Map<String, Object> user) {
        return adminPost("/realms/" + realmId + "/users", user);
    }

    /** List users in a realm. */
    public JsonNode listUsers(String realmId, int page, int size, String search) {
        String query = "?page=" + page + "&size=" + size
                + (search != null && !search.isBlank() ? "&search=" + search : "");
        return adminGet("/realms/" + realmId + "/users" + query);
    }

    /** Get a single user by userId. */
    public JsonNode getUser(String realmId, String userId) {
        return adminGet("/realms/" + realmId + "/users/" + userId);
    }

    /** Update user profile fields. */
    public JsonNode updateUser(String realmId, String userId, Map<String, Object> updates) {
        return adminPut("/realms/" + realmId + "/users/" + userId, updates);
    }

    /** Disable (deactivate) a user account. */
    public JsonNode disableUser(String realmId, String userId) {
        return adminPatch("/realms/" + realmId + "/users/" + userId + "/disable");
    }

    /** Enable (reactivate) a user account. */
    public JsonNode enableUser(String realmId, String userId) {
        return adminPatch("/realms/" + realmId + "/users/" + userId + "/enable");
    }

    /** Permanently delete a user. */
    public void deleteUser(String realmId, String userId) {
        adminDelete("/realms/" + realmId + "/users/" + userId);
    }

    /** Trigger forgot-password email for the user. */
    public JsonNode forgotPassword(String realmId, String email) {
        return adminPost("/realms/" + realmId + "/users/forgot-password", Map.of("email", email));
    }

    /** Directly set a user's password (admin override). */
    public JsonNode setPassword(String realmId, String userId, String newPassword, boolean temporary) {
        return adminPost("/realms/" + realmId + "/users/" + userId + "/set-password",
                Map.of("password", newPassword, "temporary", temporary));
    }
}
```

### UserManagementController (@RestController)

```java
package {{basePackage}}.admin;

import com.fasterxml.jackson.databind.JsonNode;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.Map;

/**
 * REST endpoints for admin user management.
 * Mount at /admin/realms/{realmId}/users.
 * Protect these routes with your JWT filter + role check.
 */
@RestController
@RequestMapping("/admin/realms/{realmId}/users")
public class UserManagementController {

    private final ApptorAdminClient adminClient;

    public UserManagementController(ApptorAdminClient adminClient) {
        this.adminClient = adminClient;
    }

    @GetMapping
    public ResponseEntity<JsonNode> listUsers(
            @PathVariable String realmId,
            @RequestParam(defaultValue = "0") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String search) {
        return ResponseEntity.ok(adminClient.listUsers(realmId, page, size, search));
    }

    @PostMapping
    public ResponseEntity<JsonNode> createUser(
            @PathVariable String realmId,
            @RequestBody Map<String, Object> user) {
        if (!user.containsKey("email") || !user.containsKey("orgRefId")) {
            return ResponseEntity.badRequest().build();
        }
        JsonNode created = adminClient.createUser(realmId, user);
        return ResponseEntity.status(HttpStatus.CREATED).body(created);
    }

    @GetMapping("/{userId}")
    public ResponseEntity<JsonNode> getUser(
            @PathVariable String realmId,
            @PathVariable String userId) {
        return ResponseEntity.ok(adminClient.getUser(realmId, userId));
    }

    @PutMapping("/{userId}")
    public ResponseEntity<JsonNode> updateUser(
            @PathVariable String realmId,
            @PathVariable String userId,
            @RequestBody Map<String, Object> updates) {
        return ResponseEntity.ok(adminClient.updateUser(realmId, userId, updates));
    }

    @PatchMapping("/{userId}/disable")
    public ResponseEntity<Void> disableUser(
            @PathVariable String realmId,
            @PathVariable String userId) {
        adminClient.disableUser(realmId, userId);
        return ResponseEntity.noContent().build();
    }

    @PatchMapping("/{userId}/enable")
    public ResponseEntity<Void> enableUser(
            @PathVariable String realmId,
            @PathVariable String userId) {
        adminClient.enableUser(realmId, userId);
        return ResponseEntity.noContent().build();
    }

    @DeleteMapping("/{userId}")
    public ResponseEntity<Void> deleteUser(
            @PathVariable String realmId,
            @PathVariable String userId) {
        adminClient.deleteUser(realmId, userId);
        return ResponseEntity.noContent().build();
    }

    @PostMapping("/{userId}/set-password")
    public ResponseEntity<Void> setPassword(
            @PathVariable String realmId,
            @PathVariable String userId,
            @RequestBody Map<String, Object> body) {
        String password = (String) body.get("password");
        boolean temporary = Boolean.TRUE.equals(body.get("temporary"));
        if (password == null || password.isBlank()) {
            return ResponseEntity.badRequest().build();
        }
        adminClient.setPassword(realmId, userId, password, temporary);
        return ResponseEntity.noContent().build();
    }
}
```

### orgRefId / userRefId Extraction from JWT

The apptorID access token includes `org_id` and `user_id` (from orgRefId/userRefId) custom claims.
Extract them in your JWT filter after processing the token:

```java
// In ApptorAuthFilter.doFilter() — after jwtProcessor.process():
JWTClaimsSet claims = jwtProcessor.process(token, null);
httpRequest.setAttribute("user_claims", claims);
httpRequest.setAttribute("sub", claims.getSubject());                    // internal user ID
httpRequest.setAttribute("user_id", claims.getClaim("user_id"));        // your app's userRefId
httpRequest.setAttribute("org_id", claims.getClaim("org_id"));          // your app's orgRefId
if (claims.getClaim("roles") != null) {
    httpRequest.setAttribute("user_roles", claims.getClaim("roles"));
}

// In a controller — read from the request:
@GetMapping("/profile")
public ResponseEntity<?> profile(HttpServletRequest request) {
    String userId = (String) request.getAttribute("user_id");   // your app's userRefId
    String orgId  = (String) request.getAttribute("org_id");    // your app's orgRefId
    // Use orgId to scope DB queries to the correct tenant/org
    return ResponseEntity.ok(Map.of("userId", userId, "orgId", orgId));
}
```
