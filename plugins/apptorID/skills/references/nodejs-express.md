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

---

## Admin API Client

### Configuration (add to .env and config.ts)

```env
APPTOR_ADMIN_ACCESS_KEY_ID=your-access-key-id
APPTOR_ADMIN_ACCESS_KEY_SECRET=your-access-key-secret
```

```typescript
// config.ts — extend the existing apptorConfig
export const apptorConfig = {
  realmUrl: process.env.APPTOR_REALM_URL!,
  clientId: process.env.APPTOR_CLIENT_ID!,
  clientSecret: process.env.APPTOR_CLIENT_SECRET!,
  redirectUri: process.env.APPTOR_REDIRECT_URI!,
  scopes: process.env.APPTOR_SCOPES || 'openid email profile',
  postLoginPath: process.env.POST_LOGIN_PATH || '/dashboard',
  postLogoutPath: process.env.POST_LOGOUT_PATH || '/',

  // Admin API credentials (access key pair, not OAuth client)
  adminAccessKeyId: process.env.APPTOR_ADMIN_ACCESS_KEY_ID!,
  adminAccessKeySecret: process.env.APPTOR_ADMIN_ACCESS_KEY_SECRET!,

  get realmBaseUrl(): string {
    return this.realmUrl.startsWith('http') ? this.realmUrl : `https://${this.realmUrl}`;
  },

  get discoveryUrl(): string {
    return `${this.realmBaseUrl}/.well-known/openid-configuration`;
  },
};
```

### ApptorAdminClient (TypeScript)

```typescript
import axios from 'axios';
import { apptorConfig } from './config';

interface AdminTokenResponse {
  access_token: string;
  expires_in: number;
  token_type: string;
}

interface UserCreateRequest {
  email: string;
  firstName?: string;
  lastName?: string;
  orgRefId: string;
  [key: string]: any;
}

/**
 * Admin API client for apptorID user management.
 * Uses client_credentials with access_key_id/access_key_secret to obtain
 * a short-lived admin token, then calls the realm Admin API.
 *
 * Token is cached and reused until 60 seconds before expiry.
 */
class ApptorAdminClient {
  private adminToken: string | null = null;
  private tokenExpiresAt: number = 0;

  /**
   * Acquire (or return cached) admin token via client_credentials grant.
   * POST {realmBaseUrl}/oidc/token
   *   grant_type=client_credentials
   *   &access_key_id={id}
   *   &access_key_secret={secret}
   */
  private async getAdminToken(): Promise<string> {
    const now = Date.now();
    // Return cached token if valid with 60-second buffer
    if (this.adminToken && now < this.tokenExpiresAt - 60_000) {
      return this.adminToken;
    }

    const params = new URLSearchParams({
      grant_type: 'client_credentials',
      access_key_id: apptorConfig.adminAccessKeyId,
      access_key_secret: apptorConfig.adminAccessKeySecret,
    });

    const response = await axios.post<AdminTokenResponse>(
      `${apptorConfig.realmBaseUrl}/oidc/token`,
      params.toString(),
      { headers: { 'Content-Type': 'application/x-www-form-urlencoded' } }
    );

    this.adminToken = response.data.access_token;
    this.tokenExpiresAt = now + response.data.expires_in * 1000;
    return this.adminToken;
  }

  private async adminRequest<T>(
    method: 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE',
    path: string,
    body?: any
  ): Promise<T> {
    const token = await this.getAdminToken();
    const url = `${apptorConfig.realmBaseUrl}${path}`;
    const response = await axios.request<T>({
      method,
      url,
      data: body,
      headers: {
        Authorization: `Bearer ${token}`,
        'Content-Type': 'application/json',
      },
    });
    return response.data;
  }

  /** Create a user in a realm. orgRefId links the user to an org. */
  async createUser(realmId: string, user: UserCreateRequest): Promise<any> {
    return this.adminRequest('POST', `/realms/${realmId}/users`, user);
  }

  /** List users in a realm. */
  async listUsers(realmId: string, params?: { page?: number; size?: number; search?: string }): Promise<any> {
    const query = params ? '?' + new URLSearchParams(params as any).toString() : '';
    return this.adminRequest('GET', `/realms/${realmId}/users${query}`);
  }

  /** Get a single user by userId. */
  async getUser(realmId: string, userId: string): Promise<any> {
    return this.adminRequest('GET', `/realms/${realmId}/users/${userId}`);
  }

  /** Update a user's profile fields. */
  async updateUser(realmId: string, userId: string, updates: Partial<UserCreateRequest>): Promise<any> {
    return this.adminRequest('PUT', `/realms/${realmId}/users/${userId}`, updates);
  }

  /** Disable (deactivate) a user account. */
  async disableUser(realmId: string, userId: string): Promise<any> {
    return this.adminRequest('PATCH', `/realms/${realmId}/users/${userId}/disable`);
  }

  /** Enable (reactivate) a user account. */
  async enableUser(realmId: string, userId: string): Promise<any> {
    return this.adminRequest('PATCH', `/realms/${realmId}/users/${userId}/enable`);
  }

  /** Permanently delete a user. */
  async deleteUser(realmId: string, userId: string): Promise<void> {
    await this.adminRequest('DELETE', `/realms/${realmId}/users/${userId}`);
  }

  /** Trigger a forgot-password email for the user. */
  async forgotPassword(realmId: string, email: string): Promise<any> {
    return this.adminRequest('POST', `/realms/${realmId}/users/forgot-password`, { email });
  }

  /** Directly set a user's password (admin override). */
  async setPassword(realmId: string, userId: string, newPassword: string, temporary = false): Promise<any> {
    return this.adminRequest('POST', `/realms/${realmId}/users/${userId}/set-password`, {
      password: newPassword,
      temporary,
    });
  }
}

export const adminClient = new ApptorAdminClient();
```

### User Management Express Routes

```typescript
import { Router, Request, Response } from 'express';
import { adminClient } from './adminClient';
import { requireAuth, requireRoles } from './middleware';

const userManagementRouter = Router();

// All routes require authentication; admin routes also require 'admin' role.

/** GET /admin/users — List users in the realm. */
userManagementRouter.get('/', requireAuth, requireRoles('admin'), async (req: Request, res: Response) => {
  try {
    const { realmId } = req.params;
    const { page, size, search } = req.query as Record<string, string>;
    const users = await adminClient.listUsers(realmId, { page: Number(page) || 0, size: Number(size) || 20, search });
    res.json(users);
  } catch (error: any) {
    res.status(error.response?.status || 500).json({ error: error.response?.data || error.message });
  }
});

/** POST /admin/users — Create a new user. orgRefId required in body. */
userManagementRouter.post('/', requireAuth, requireRoles('admin'), async (req: Request, res: Response) => {
  try {
    const { realmId } = req.params;
    const { email, firstName, lastName, orgRefId, ...rest } = req.body;
    if (!email || !orgRefId) {
      return res.status(400).json({ error: 'email and orgRefId are required' });
    }
    const user = await adminClient.createUser(realmId, { email, firstName, lastName, orgRefId, ...rest });
    res.status(201).json(user);
  } catch (error: any) {
    res.status(error.response?.status || 500).json({ error: error.response?.data || error.message });
  }
});

/** GET /admin/users/:userId — Get a single user. */
userManagementRouter.get('/:userId', requireAuth, requireRoles('admin'), async (req: Request, res: Response) => {
  try {
    const { realmId, userId } = req.params;
    const user = await adminClient.getUser(realmId, userId);
    res.json(user);
  } catch (error: any) {
    res.status(error.response?.status || 500).json({ error: error.response?.data || error.message });
  }
});

/** PUT /admin/users/:userId — Update a user. */
userManagementRouter.put('/:userId', requireAuth, requireRoles('admin'), async (req: Request, res: Response) => {
  try {
    const { realmId, userId } = req.params;
    const user = await adminClient.updateUser(realmId, userId, req.body);
    res.json(user);
  } catch (error: any) {
    res.status(error.response?.status || 500).json({ error: error.response?.data || error.message });
  }
});

/** PATCH /admin/users/:userId/disable — Disable a user. */
userManagementRouter.patch('/:userId/disable', requireAuth, requireRoles('admin'), async (req: Request, res: Response) => {
  try {
    const { realmId, userId } = req.params;
    await adminClient.disableUser(realmId, userId);
    res.status(204).send();
  } catch (error: any) {
    res.status(error.response?.status || 500).json({ error: error.response?.data || error.message });
  }
});

/** PATCH /admin/users/:userId/enable — Enable a user. */
userManagementRouter.patch('/:userId/enable', requireAuth, requireRoles('admin'), async (req: Request, res: Response) => {
  try {
    const { realmId, userId } = req.params;
    await adminClient.enableUser(realmId, userId);
    res.status(204).send();
  } catch (error: any) {
    res.status(error.response?.status || 500).json({ error: error.response?.data || error.message });
  }
});

/** DELETE /admin/users/:userId — Delete a user. */
userManagementRouter.delete('/:userId', requireAuth, requireRoles('admin'), async (req: Request, res: Response) => {
  try {
    const { realmId, userId } = req.params;
    await adminClient.deleteUser(realmId, userId);
    res.status(204).send();
  } catch (error: any) {
    res.status(error.response?.status || 500).json({ error: error.response?.data || error.message });
  }
});

/** POST /admin/users/:userId/set-password — Admin password reset. */
userManagementRouter.post('/:userId/set-password', requireAuth, requireRoles('admin'), async (req: Request, res: Response) => {
  try {
    const { realmId, userId } = req.params;
    const { password, temporary } = req.body;
    if (!password) return res.status(400).json({ error: 'password is required' });
    await adminClient.setPassword(realmId, userId, password, temporary ?? false);
    res.status(204).send();
  } catch (error: any) {
    res.status(error.response?.status || 500).json({ error: error.response?.data || error.message });
  }
});

// Mount in app.ts:
// app.use('/admin/realms/:realmId/users', userManagementRouter);
export { userManagementRouter };
```

### orgRefId / userRefId Extraction from JWT

The apptorID access token includes `org_id` and `user_id` (from orgRefId/userRefId) custom claims.
Extract them in your middleware after verifying the JWT:

```typescript
// In requireAuth middleware — after jwt.verify():
(req as any).user = decoded;
(req as any).userId = (decoded as any).sub;                  // internal user ID
(req as any).userRefId = (decoded as any).user_id;           // your app's userRefId
(req as any).orgRefId = (decoded as any).org_id;             // your app's orgRefId
(req as any).userRoles = (decoded as any).roles || [];

// In a route handler:
router.get('/profile', requireAuth, (req: Request, res: Response) => {
  const { userId, userRefId, orgRefId } = req as any;
  // Use orgRefId to scope DB queries to the correct tenant/org
  res.json({ userId, userRefId, orgRefId });
});
```
