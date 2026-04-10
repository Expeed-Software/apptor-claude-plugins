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
     */
    public String buildAuthorizationUrl(String state, String codeChallenge, String nonce) {
        return getAuthorizationEndpoint()
                + "?client_id=" + properties.getClientId()
                + "&redirect_uri=" + properties.getRedirectUri()
                + "&response_type=code"
                + "&scope=" + properties.getScopes().replace(",", "%20")
                + "&state=" + state
                + "&nonce=" + nonce
                + "&code_challenge=" + codeChallenge
                + "&code_challenge_method=S256";
    }

    /**
     * Exchange an authorization code for tokens.
     */
    public JsonNode exchangeCodeForTokens(String code, String codeVerifier) {
        MultiValueMap<String, String> formData = new LinkedMultiValueMap<>();
        formData.add("grant_type", "authorization_code");
        formData.add("code", code);
        formData.add("client_id", properties.getClientId());
        formData.add("client_secret", properties.getClientSecret());
        formData.add("redirect_uri", properties.getRedirectUri());
        formData.add("code_verifier", codeVerifier);

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
     * Initiates the OAuth2 Authorization Code flow with PKCE.
     * Redirects the user to apptorID's authorization endpoint.
     */
    @GetMapping("/login")
    public RedirectView login(HttpSession session) {
        String state = generateSecureRandom();
        String nonce = generateSecureRandom();
        String codeVerifier = PkceUtil.generateCodeVerifier();
        String codeChallenge = PkceUtil.generateCodeChallenge(codeVerifier);

        // Store PKCE and state in session for validation on callback
        session.setAttribute("oauth_state", state);
        session.setAttribute("oauth_nonce", nonce);
        session.setAttribute("pkce_verifier", codeVerifier);

        String authUrl = oidcClient.buildAuthorizationUrl(state, codeChallenge, nonce);
        return new RedirectView(authUrl);
    }

    /**
     * Handles the OAuth2 callback. Exchanges the authorization code for tokens.
     */
    @GetMapping("/callback")
    public RedirectView callback(
            @RequestParam("code") String code,
            @RequestParam("state") String state,
            HttpSession session
    ) {
        // Validate state to prevent CSRF
        String savedState = (String) session.getAttribute("oauth_state");
        if (savedState == null || !savedState.equals(state)) {
            throw new SecurityException("Invalid OAuth2 state parameter — possible CSRF attack");
        }

        String codeVerifier = (String) session.getAttribute("pkce_verifier");
        if (codeVerifier == null) {
            throw new SecurityException("Missing PKCE verifier — session may have expired");
        }

        // Exchange code for tokens
        JsonNode tokens = oidcClient.exchangeCodeForTokens(code, codeVerifier);

        // Store tokens in session
        session.setAttribute("access_token", tokens.get("access_token").asText());
        session.setAttribute("id_token", tokens.get("id_token").asText());
        if (tokens.has("refresh_token")) {
            session.setAttribute("refresh_token", tokens.get("refresh_token").asText());
        }

        // Clean up PKCE/state
        session.removeAttribute("oauth_state");
        session.removeAttribute("oauth_nonce");
        session.removeAttribute("pkce_verifier");

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
