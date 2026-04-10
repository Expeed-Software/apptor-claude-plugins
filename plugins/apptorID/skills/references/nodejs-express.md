# Node.js Express — apptorID Integration Templates

## Table of Contents
1. [Dependencies](#dependencies)
2. [Configuration](#configuration)
3. [OIDC Client Service](#oidc-client-service)
4. [PKCE Utility](#pkce-utility)
5. [Auth Routes](#auth-routes)
6. [Auth Middleware](#auth-middleware)
7. [Client-Hosted Login Routes](#client-hosted-login-routes)
8. [Multi-Tenant Resolver](#multi-tenant-resolver)

---

## Dependencies

```bash
npm install express express-session jsonwebtoken jwks-rsa axios crypto
# or
yarn add express express-session jsonwebtoken jwks-rsa axios
```

For TypeScript projects, also install:
```bash
npm install -D @types/express @types/express-session @types/jsonwebtoken
```

---

## Configuration

### .env (Single-Tenant)
```env
APPTOR_REALM_URL=acme-x1y2.sandbox.auth.apptor.io
APPTOR_CLIENT_ID=your-client-id
APPTOR_CLIENT_SECRET=your-client-secret
APP_BASE_URL=http://localhost:3000
APPTOR_REDIRECT_URI=http://localhost:3000/auth/callback
APPTOR_SCOPES=openid email profile
SESSION_SECRET=your-secure-session-secret
POST_LOGIN_PATH=/dashboard
POST_LOGOUT_PATH=/
```

### config.ts
```typescript
export const apptorConfig = {
  realmUrl: process.env.APPTOR_REALM_URL!,
  clientId: process.env.APPTOR_CLIENT_ID!,
  clientSecret: process.env.APPTOR_CLIENT_SECRET!,
  redirectUri: process.env.APPTOR_REDIRECT_URI!,
  scopes: process.env.APPTOR_SCOPES || 'openid email profile',
  postLoginPath: process.env.POST_LOGIN_PATH || '/dashboard',
  postLogoutPath: process.env.POST_LOGOUT_PATH || '/',

  get discoveryUrl(): string {
    const base = this.realmUrl.startsWith('http') ? this.realmUrl : `https://${this.realmUrl}`;
    return `${base}/.well-known/openid-configuration`;
  },

  get realmBaseUrl(): string {
    return this.realmUrl.startsWith('http') ? this.realmUrl : `https://${this.realmUrl}`;
  },
};
```

---

## OIDC Client Service

```typescript
import axios from 'axios';
import { apptorConfig } from './config';

interface OidcDiscovery {
  issuer: string;
  authorization_endpoint: string;
  token_endpoint: string;
  userinfo_endpoint: string;
  jwks_uri: string;
  end_session_endpoint: string;
}

interface TokenResponse {
  access_token: string;
  id_token: string;
  refresh_token?: string;
  expires_in: number;
  token_type: string;
}

class ApptorOidcClient {
  private discovery: OidcDiscovery | null = null;

  async initialize(): Promise<void> {
    const response = await axios.get<OidcDiscovery>(apptorConfig.discoveryUrl);
    this.discovery = response.data;
    console.log(`apptorID discovery loaded from ${apptorConfig.discoveryUrl}`);
  }

  private getDiscovery(): OidcDiscovery {
    if (!this.discovery) throw new Error('OIDC client not initialized. Call initialize() first.');
    return this.discovery;
  }

  /**
   * Build authorization URL for redirecting to apptorID login.
   * Backend apps: no PKCE needed — client_secret authenticates the token exchange.
   */
  buildAuthorizationUrl(state: string, nonce: string): string {
    const discovery = this.getDiscovery();
    const params = new URLSearchParams({
      client_id: apptorConfig.clientId,
      redirect_uri: apptorConfig.redirectUri,
      response_type: 'code',
      scope: apptorConfig.scopes,
      state,
      nonce,
    });
    return `${discovery.authorization_endpoint}?${params.toString()}`;
  }

  /**
   * Exchange authorization code for tokens using client_secret (backend flow).
   * client_secret comes from process.env.APPTOR_CLIENT_SECRET — never exposed to browser.
   */
  async exchangeCodeForTokens(code: string): Promise<TokenResponse> {
    const discovery = this.getDiscovery();
    const params = new URLSearchParams({
      grant_type: 'authorization_code',
      code,
      client_id: apptorConfig.clientId,
      client_secret: apptorConfig.clientSecret,
      redirect_uri: apptorConfig.redirectUri,
    });

    const response = await axios.post<TokenResponse>(discovery.token_endpoint, params.toString(), {
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    });
    return response.data;
  }

  /**
   * Refresh access token using refresh token.
   */
  async refreshToken(refreshToken: string): Promise<TokenResponse> {
    const discovery = this.getDiscovery();
    const params = new URLSearchParams({
      grant_type: 'refresh_token',
      refresh_token: refreshToken,
      client_id: apptorConfig.clientId,
      client_secret: apptorConfig.clientSecret,
    });

    const response = await axios.post<TokenResponse>(discovery.token_endpoint, params.toString(), {
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    });
    return response.data;
  }

  /**
   * Fetch user info using access token.
   */
  async getUserInfo(accessToken: string): Promise<Record<string, any>> {
    const discovery = this.getDiscovery();
    const response = await axios.get(discovery.userinfo_endpoint, {
      headers: { Authorization: `Bearer ${accessToken}` },
    });
    return response.data;
  }

  /**
   * Build logout URL.
   */
  buildLogoutUrl(postLogoutRedirectUri: string): string {
    const discovery = this.getDiscovery();
    return `${discovery.end_session_endpoint}?post_logout_redirect_uri=${encodeURIComponent(postLogoutRedirectUri)}`;
  }

  /**
   * Get JWKS URI for token validation.
   */
  getJwksUri(): string {
    return this.getDiscovery().jwks_uri;
  }

  getIssuer(): string {
    return this.getDiscovery().issuer;
  }
}

export const oidcClient = new ApptorOidcClient();
```

---

## PKCE Utility

```typescript
import crypto from 'crypto';

export function generateCodeVerifier(): string {
  return crypto.randomBytes(64).toString('base64url');
}

export function generateCodeChallenge(verifier: string): string {
  return crypto.createHash('sha256').update(verifier).digest('base64url');
}

export function generateSecureRandom(): string {
  return crypto.randomBytes(32).toString('base64url');
}
```

---

## Auth Routes

```typescript
import { Router, Request, Response } from 'express';
import { oidcClient } from './oidcClient';
import { apptorConfig } from './config';
import { generateSecureRandom } from './pkce';

const authRouter = Router();

/**
 * GET /auth/login — Initiates OAuth2 Authorization Code flow.
 * Backend apps use client_secret for token exchange — no PKCE needed.
 */
authRouter.get('/login', (req: Request, res: Response) => {
  const state = generateSecureRandom();
  const nonce = generateSecureRandom();

  // Store in session for validation on callback
  req.session.oauthState = state;
  req.session.oauthNonce = nonce;

  const authUrl = oidcClient.buildAuthorizationUrl(state, nonce);
  res.redirect(authUrl);
});

/**
 * GET /auth/callback — Handles OAuth2 redirect.
 * Receives ?code=xxx&state=xxx, validates state, exchanges code for tokens
 * using client_id + client_secret (from process.env.APPTOR_CLIENT_SECRET),
 * stores tokens in session, and redirects to dashboard.
 */
authRouter.get('/callback', async (req: Request, res: Response) => {
  try {
    const { code, state } = req.query as { code: string; state: string };

    // 1. Validate state (CSRF protection)
    if (!req.session.oauthState || req.session.oauthState !== state) {
      return res.status(403).json({ error: 'Invalid state — possible CSRF attack' });
    }

    // 2. Exchange code for tokens using client_secret on the backend
    const tokens = await oidcClient.exchangeCodeForTokens(code);

    // 3. Store tokens in session
    req.session.accessToken = tokens.access_token;
    req.session.idToken = tokens.id_token;
    req.session.refreshToken = tokens.refresh_token;

    // 4. Clean up state
    delete req.session.oauthState;
    delete req.session.oauthNonce;

    // 5. Redirect to dashboard
    res.redirect(apptorConfig.postLoginPath);
  } catch (error: any) {
    console.error('Auth callback error:', error.response?.data || error.message);
    res.status(500).json({ error: 'Authentication failed' });
  }
});

/**
 * GET /auth/refresh — Refreshes the access token.
 */
authRouter.get('/refresh', async (req: Request, res: Response) => {
  try {
    if (!req.session.refreshToken) {
      return res.redirect('/auth/login');
    }

    const tokens = await oidcClient.refreshToken(req.session.refreshToken);
    req.session.accessToken = tokens.access_token;
    if (tokens.refresh_token) {
      req.session.refreshToken = tokens.refresh_token;
    }

    const returnTo = req.session.lastPage || apptorConfig.postLoginPath;
    res.redirect(returnTo);
  } catch (error: any) {
    console.error('Token refresh failed:', error.message);
    res.redirect('/auth/login');
  }
});

/**
 * GET /auth/logout — Clears session and redirects to apptorID logout.
 */
authRouter.get('/logout', (req: Request, res: Response) => {
  const logoutUrl = oidcClient.buildLogoutUrl(apptorConfig.postLogoutPath);
  req.session.destroy(() => {
    res.redirect(logoutUrl);
  });
});

/**
 * GET /auth/me — Returns the authenticated user's info.
 */
authRouter.get('/me', async (req: Request, res: Response) => {
  try {
    if (!req.session.accessToken) {
      return res.status(401).json({ error: 'Not authenticated' });
    }
    const userInfo = await oidcClient.getUserInfo(req.session.accessToken);
    res.json(userInfo);
  } catch (error: any) {
    res.status(401).json({ error: 'Failed to fetch user info' });
  }
});

export { authRouter };
```

### Express Session Type Extension (TypeScript)

```typescript
// types/express-session.d.ts
import 'express-session';

declare module 'express-session' {
  interface SessionData {
    oauthState?: string;
    oauthNonce?: string;
    accessToken?: string;
    idToken?: string;
    refreshToken?: string;
    lastPage?: string;
    orgId?: string;
  }
}
```

### App Setup

```typescript
import express from 'express';
import session from 'express-session';
import { oidcClient } from './auth/oidcClient';
import { authRouter } from './auth/routes';
import { requireAuth } from './auth/middleware';

const app = express();

app.use(session({
  secret: process.env.SESSION_SECRET!,
  resave: false,
  saveUninitialized: false,
  cookie: { secure: process.env.NODE_ENV === 'production', httpOnly: true, maxAge: 24 * 60 * 60 * 1000 },
}));

app.use('/auth', authRouter);

// Protected routes
app.use('/dashboard', requireAuth, dashboardRouter);
app.use('/api', requireAuth, apiRouter);

async function start() {
  await oidcClient.initialize();
  app.listen(3000, () => console.log('Server running on port 3000'));
}

start();
```

---

## Auth Middleware

```typescript
import { Request, Response, NextFunction } from 'express';
import jwt from 'jsonwebtoken';
import jwksClient from 'jwks-rsa';
import { oidcClient } from './oidcClient';

let jwksClientInstance: jwksClient.JwksClient | null = null;

function getJwksClient(): jwksClient.JwksClient {
  if (!jwksClientInstance) {
    jwksClientInstance = jwksClient({
      jwksUri: oidcClient.getJwksUri(),
      cache: true,
      cacheMaxAge: 86400000, // 24 hours
      rateLimit: true,
    });
  }
  return jwksClientInstance;
}

function getSigningKey(header: jwt.JwtHeader, callback: jwt.SigningKeyCallback): void {
  getJwksClient().getSigningKey(header.kid, (err, key) => {
    if (err) return callback(err);
    const signingKey = key?.getPublicKey();
    callback(null, signingKey);
  });
}

/**
 * Middleware: Requires authentication via session or Bearer token.
 * For web routes (session-based): redirects to login if not authenticated.
 * For API routes (Bearer token): returns 401 JSON error.
 */
export function requireAuth(req: Request, res: Response, next: NextFunction): void {
  // Check Bearer token first (API clients)
  const authHeader = req.headers.authorization;
  if (authHeader?.startsWith('Bearer ')) {
    const token = authHeader.substring(7);
    jwt.verify(token, getSigningKey, { algorithms: ['RS256'] }, (err, decoded) => {
      if (err) {
        res.status(401).json({ error: 'invalid_token', message: err.message });
        return;
      }
      (req as any).user = decoded;
      (req as any).userId = (decoded as any).sub;
      (req as any).userRoles = (decoded as any).roles || [];
      next();
    });
    return;
  }

  // Check session (web app)
  if (req.session?.accessToken) {
    jwt.verify(req.session.accessToken, getSigningKey, { algorithms: ['RS256'] }, (err, decoded) => {
      if (err) {
        // Token expired — try refresh
        res.redirect('/auth/refresh');
        return;
      }
      (req as any).user = decoded;
      (req as any).userId = (decoded as any).sub;
      (req as any).userRoles = (decoded as any).roles || [];
      req.session.lastPage = req.originalUrl;
      next();
    });
    return;
  }

  // Not authenticated
  if (req.path.startsWith('/api')) {
    res.status(401).json({ error: 'unauthorized', message: 'Authentication required' });
  } else {
    res.redirect('/auth/login');
  }
}

/**
 * Middleware: Requires specific roles.
 * Usage: app.get('/admin', requireAuth, requireRoles('admin'), adminHandler);
 */
export function requireRoles(...roles: string[]) {
  return (req: Request, res: Response, next: NextFunction): void => {
    const userRoles: string[] = (req as any).userRoles || [];
    const hasRole = roles.some((role) => userRoles.includes(role));
    if (!hasRole) {
      res.status(403).json({ error: 'forbidden', message: `Requires one of: ${roles.join(', ')}` });
      return;
    }
    next();
  };
}
```

---

## Client-Hosted Login Routes

If the developer hosts their own login page:

```typescript
import { Router, Request, Response } from 'express';
import axios from 'axios';
import { apptorConfig } from './config';

const clientLoginRouter = Router();

/**
 * POST /auth/pre-authorize — Validates credentials via apptorID pre-authorize.
 * Called from the tenant's own login form.
 */
clientLoginRouter.post('/pre-authorize', async (req: Request, res: Response) => {
  try {
    const { username, password, requestId } = req.body;

    const params = new URLSearchParams({
      username,
      password,
      request_id: requestId,
    });

    const response = await axios.post(
      `${apptorConfig.realmBaseUrl}/oidc/pre-authorize`,
      params.toString(),
      { headers: { 'Content-Type': 'application/x-www-form-urlencoded' } }
    );

    if (response.data.preAuthToken) {
      const exchangeUrl =
        `${apptorConfig.realmBaseUrl}/oidc/auth` +
        `?request_id=${requestId}` +
        `&preAuthToken=${response.data.preAuthToken}`;
      res.json({ redirectUrl: exchangeUrl });
    } else {
      res.status(401).json({ error: 'Authentication failed' });
    }
  } catch (error: any) {
    console.error('Pre-authorize failed:', error.response?.data || error.message);
    res.status(401).json({ error: error.response?.data?.message || 'Authentication failed' });
  }
});

/**
 * GET /auth/social/:providerId — Redirects to external IdP via apptorID.
 */
clientLoginRouter.get('/social/:providerId', (req: Request, res: Response) => {
  const { providerId } = req.params;
  const { requestId } = req.query;
  const socialUrl =
    `${apptorConfig.realmBaseUrl}/oidc/auth` +
    `?provider_id=${providerId}` +
    `&request_id=${requestId}`;
  res.redirect(socialUrl);
});

export { clientLoginRouter };
```

---

## Multi-Tenant Resolver

```typescript
import { Request } from 'express';

interface OrgAuthConfig {
  orgId: string;
  realmUrl: string;
  clientId: string;
  clientSecret: string;
  enabledIdps: string[];
  loginType: 'hosted' | 'client';
}

/**
 * Resolves the current tenant's apptorID config from the request.
 * Adapt the resolution strategy to your app's tenancy model.
 */
export async function resolveTenant(req: Request, configRepository: any): Promise<OrgAuthConfig> {
  // Strategy 1: Subdomain
  const host = req.hostname;
  if (host.includes('.')) {
    const subdomain = host.split('.')[0];
    const config = await configRepository.findByIdentifier(subdomain);
    if (config) return config;
  }

  // Strategy 2: Header
  const tenantId = req.headers['x-tenant-id'] as string;
  if (tenantId) {
    const config = await configRepository.findByOrgId(tenantId);
    if (config) return config;
  }

  // Strategy 3: Session
  if (req.session?.orgId) {
    const config = await configRepository.findByOrgId(req.session.orgId);
    if (config) return config;
  }

  throw new Error('Cannot resolve tenant from request');
}
```

See `references/multitenant-db.md` for the database schema and repository.
