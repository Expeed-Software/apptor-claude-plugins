# React Frontend — apptorID Integration Templates

## Table of Contents
1. [Dependencies](#dependencies)
2. [Auth Context & Provider](#auth-context--provider)
3. [PKCE Utility](#pkce-utility)
4. [Auth Hook](#auth-hook)
5. [Login Page (Client-Hosted)](#login-page-client-hosted)
6. [Callback Handler](#callback-handler)
7. [Protected Route](#protected-route)
8. [Social Login Buttons](#social-login-buttons)
9. [Token Refresh](#token-refresh)

---

## Dependencies

```bash
npm install axios react-router-dom
# TypeScript:
npm install -D @types/react-router-dom
```

---

## Auth Context & Provider

```tsx
// src/auth/AuthContext.tsx
import React, { createContext, useContext, useState, useCallback, useEffect, type ReactNode } from 'react';

interface User {
  sub: string;
  email: string;
  name: string;
  roles: string[];
  [key: string]: any;
}

interface AuthContextType {
  user: User | null;
  accessToken: string | null;
  isAuthenticated: boolean;
  isLoading: boolean;
  login: () => void;
  loginWithProvider: (providerId: string) => void;
  logout: () => void;
  getAccessToken: () => string | null;
}

const AuthContext = createContext<AuthContextType | null>(null);

const APPTOR_REALM_URL = import.meta.env.VITE_APPTOR_REALM_URL;
const APPTOR_CLIENT_ID = import.meta.env.VITE_APPTOR_CLIENT_ID;
const REDIRECT_URI = import.meta.env.VITE_APPTOR_REDIRECT_URI;
const SCOPES = import.meta.env.VITE_APPTOR_SCOPES || 'openid email profile';
const POST_LOGIN_PATH = import.meta.env.VITE_POST_LOGIN_PATH || '/dashboard';
const POST_LOGOUT_PATH = import.meta.env.VITE_POST_LOGOUT_PATH || '/';

function getRealmBaseUrl(): string {
  return APPTOR_REALM_URL.startsWith('http') ? APPTOR_REALM_URL : `https://${APPTOR_REALM_URL}`;
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<User | null>(null);
  const [accessToken, setAccessToken] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(true);

  // On mount, check if we have a stored token
  useEffect(() => {
    const token = sessionStorage.getItem('access_token');
    if (token) {
      try {
        const payload = parseJwt(token);
        // Check if token is expired
        if (payload.exp * 1000 > Date.now()) {
          setAccessToken(token);
          setUser({
            sub: payload.sub,
            email: payload.email,
            name: payload.name || payload.given_name || payload.email,
            roles: payload.roles || [],
            ...payload,
          });
        } else {
          sessionStorage.removeItem('access_token');
          sessionStorage.removeItem('id_token');
          sessionStorage.removeItem('refresh_token');
        }
      } catch {
        sessionStorage.removeItem('access_token');
      }
    }
    setIsLoading(false);
  }, []);

  const login = useCallback(async () => {
    const state = generateSecureRandom();
    const nonce = generateSecureRandom();
    const codeVerifier = generateCodeVerifier();
    const codeChallenge = await generateCodeChallenge(codeVerifier);

    // Store PKCE and state for callback validation
    sessionStorage.setItem('oauth_state', state);
    sessionStorage.setItem('oauth_nonce', nonce);
    sessionStorage.setItem('pkce_verifier', codeVerifier);

    const params = new URLSearchParams({
      client_id: APPTOR_CLIENT_ID,
      redirect_uri: REDIRECT_URI,
      response_type: 'code',
      scope: SCOPES,
      state,
      nonce,
      code_challenge: codeChallenge,
      code_challenge_method: 'S256',
    });

    window.location.href = `${getRealmBaseUrl()}/oidc/auth?${params.toString()}`;
  }, []);

  const loginWithProvider = useCallback((providerId: string) => {
    const state = sessionStorage.getItem('oauth_state') || generateSecureRandom();
    sessionStorage.setItem('oauth_state', state);

    const params = new URLSearchParams({
      client_id: APPTOR_CLIENT_ID,
      redirect_uri: REDIRECT_URI,
      response_type: 'code',
      scope: SCOPES,
      state,
      provider_id: providerId,
    });

    window.location.href = `${getRealmBaseUrl()}/oidc/auth?${params.toString()}`;
  }, []);

  const logout = useCallback(() => {
    sessionStorage.removeItem('access_token');
    sessionStorage.removeItem('id_token');
    sessionStorage.removeItem('refresh_token');
    setAccessToken(null);
    setUser(null);

    const logoutUrl = `${getRealmBaseUrl()}/oidc/logout?post_logout_redirect_uri=${encodeURIComponent(window.location.origin + POST_LOGOUT_PATH)}`;
    window.location.href = logoutUrl;
  }, []);

  const getAccessToken = useCallback(() => accessToken, [accessToken]);

  const handleTokens = useCallback((tokens: { access_token: string; id_token: string; refresh_token?: string }) => {
    sessionStorage.setItem('access_token', tokens.access_token);
    sessionStorage.setItem('id_token', tokens.id_token);
    if (tokens.refresh_token) {
      sessionStorage.setItem('refresh_token', tokens.refresh_token);
    }

    setAccessToken(tokens.access_token);
    const payload = parseJwt(tokens.access_token);
    setUser({
      sub: payload.sub,
      email: payload.email,
      name: payload.name || payload.given_name || payload.email,
      roles: payload.roles || [],
      ...payload,
    });
  }, []);

  return (
    <AuthContext.Provider
      value={{
        user,
        accessToken,
        isAuthenticated: !!user,
        isLoading,
        login,
        loginWithProvider,
        logout,
        getAccessToken,
      }}
    >
      {/* Expose handleTokens for the callback component */}
      <AuthCallbackContext.Provider value={{ handleTokens }}>
        {children}
      </AuthCallbackContext.Provider>
    </AuthContext.Provider>
  );
}

// Internal context for the callback handler to set tokens
interface AuthCallbackContextType {
  handleTokens: (tokens: { access_token: string; id_token: string; refresh_token?: string }) => void;
}
export const AuthCallbackContext = createContext<AuthCallbackContextType>({ handleTokens: () => {} });

export function useAuth(): AuthContextType {
  const context = useContext(AuthContext);
  if (!context) throw new Error('useAuth must be used within AuthProvider');
  return context;
}

// --- Utilities ---

function parseJwt(token: string): any {
  const base64Url = token.split('.')[1];
  const base64 = base64Url.replace(/-/g, '+').replace(/_/g, '/');
  const jsonPayload = decodeURIComponent(
    atob(base64)
      .split('')
      .map((c) => '%' + ('00' + c.charCodeAt(0).toString(16)).slice(-2))
      .join('')
  );
  return JSON.parse(jsonPayload);
}

function generateSecureRandom(): string {
  const array = new Uint8Array(32);
  crypto.getRandomValues(array);
  return btoa(String.fromCharCode(...array))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
}

function generateCodeVerifier(): string {
  const array = new Uint8Array(64);
  crypto.getRandomValues(array);
  return btoa(String.fromCharCode(...array))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
}

async function generateCodeChallenge(verifier: string): Promise<string> {
  const encoder = new TextEncoder();
  const data = encoder.encode(verifier);
  const digest = await crypto.subtle.digest('SHA-256', data);
  return btoa(String.fromCharCode(...new Uint8Array(digest)))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
}
```

### Environment Variables

```env
# .env
VITE_APPTOR_REALM_URL=acme-x1y2.sandbox.auth.apptor.io
VITE_APPTOR_CLIENT_ID=your-client-id
VITE_APPTOR_REDIRECT_URI=http://localhost:5173/auth/callback
VITE_APPTOR_SCOPES=openid email profile
VITE_POST_LOGIN_PATH=/dashboard
VITE_POST_LOGOUT_PATH=/
```

---

## Callback Handler

```tsx
// src/auth/AuthCallback.tsx
import { useEffect, useContext, useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import axios from 'axios';
import { AuthCallbackContext } from './AuthContext';

const APPTOR_REALM_URL = import.meta.env.VITE_APPTOR_REALM_URL;
const APPTOR_CLIENT_ID = import.meta.env.VITE_APPTOR_CLIENT_ID;
const REDIRECT_URI = import.meta.env.VITE_APPTOR_REDIRECT_URI;
const POST_LOGIN_PATH = import.meta.env.VITE_POST_LOGIN_PATH || '/dashboard';

function getRealmBaseUrl(): string {
  return APPTOR_REALM_URL.startsWith('http') ? APPTOR_REALM_URL : `https://${APPTOR_REALM_URL}`;
}

export function AuthCallback() {
  const [searchParams] = useSearchParams();
  const navigate = useNavigate();
  const { handleTokens } = useContext(AuthCallbackContext);
  const [error, setError] = useState<string>('');

  useEffect(() => {
    const exchangeCode = async () => {
      const code = searchParams.get('code');
      const state = searchParams.get('state');

      if (!code) {
        setError('Missing authorization code');
        return;
      }

      // Validate state
      const savedState = sessionStorage.getItem('oauth_state');
      if (savedState && savedState !== state) {
        setError('Invalid state parameter — possible CSRF attack');
        return;
      }

      const codeVerifier = sessionStorage.getItem('pkce_verifier');
      if (!codeVerifier) {
        setError('Missing PKCE verifier — session may have expired');
        return;
      }

      try {
        // Exchange code for tokens
        const params = new URLSearchParams({
          grant_type: 'authorization_code',
          code,
          client_id: APPTOR_CLIENT_ID,
          redirect_uri: REDIRECT_URI,
          code_verifier: codeVerifier,
        });

        const response = await axios.post(
          `${getRealmBaseUrl()}/oidc/token`,
          params.toString(),
          { headers: { 'Content-Type': 'application/x-www-form-urlencoded' } }
        );

        // Store tokens via context
        handleTokens(response.data);

        // Clean up
        sessionStorage.removeItem('oauth_state');
        sessionStorage.removeItem('oauth_nonce');
        sessionStorage.removeItem('pkce_verifier');

        // Redirect to post-login page
        navigate(POST_LOGIN_PATH, { replace: true });
      } catch (err: any) {
        console.error('Token exchange failed:', err);
        setError(err.response?.data?.error_description || 'Authentication failed');
      }
    };

    exchangeCode();
  }, [searchParams, navigate, handleTokens]);

  if (error) {
    return (
      <div style={{ padding: '2rem', textAlign: 'center' }}>
        <h2>Authentication Error</h2>
        <p style={{ color: 'red' }}>{error}</p>
        <button onClick={() => navigate('/auth/login')}>Try Again</button>
      </div>
    );
  }

  return (
    <div style={{ padding: '2rem', textAlign: 'center' }}>
      <p>Completing authentication...</p>
    </div>
  );
}
```

---

## Protected Route

```tsx
// src/auth/ProtectedRoute.tsx
import { Navigate, useLocation } from 'react-router-dom';
import { useAuth } from './AuthContext';

interface ProtectedRouteProps {
  children: React.ReactNode;
  requiredRoles?: string[];
}

export function ProtectedRoute({ children, requiredRoles }: ProtectedRouteProps) {
  const { isAuthenticated, isLoading, user, login } = useAuth();
  const location = useLocation();

  if (isLoading) {
    return <div style={{ padding: '2rem', textAlign: 'center' }}>Loading...</div>;
  }

  if (!isAuthenticated) {
    // Save the current location so we can redirect back after login
    sessionStorage.setItem('redirect_after_login', location.pathname);
    login();
    return null;
  }

  if (requiredRoles && requiredRoles.length > 0) {
    const userRoles = user?.roles || [];
    const hasRole = requiredRoles.some((role) => userRoles.includes(role));
    if (!hasRole) {
      return (
        <div style={{ padding: '2rem', textAlign: 'center' }}>
          <h2>Access Denied</h2>
          <p>You don't have permission to access this page.</p>
          <p>Required roles: {requiredRoles.join(', ')}</p>
        </div>
      );
    }
  }

  return <>{children}</>;
}
```

### Router Setup

```tsx
// src/App.tsx
import { BrowserRouter, Routes, Route } from 'react-router-dom';
import { AuthProvider } from './auth/AuthContext';
import { AuthCallback } from './auth/AuthCallback';
import { ProtectedRoute } from './auth/ProtectedRoute';

function App() {
  return (
    <BrowserRouter>
      <AuthProvider>
        <Routes>
          {/* Public routes */}
          <Route path="/" element={<HomePage />} />
          <Route path="/auth/callback" element={<AuthCallback />} />

          {/* Protected routes */}
          <Route
            path="/dashboard"
            element={
              <ProtectedRoute>
                <DashboardPage />
              </ProtectedRoute>
            }
          />
          <Route
            path="/admin"
            element={
              <ProtectedRoute requiredRoles={['admin']}>
                <AdminPage />
              </ProtectedRoute>
            }
          />
        </Routes>
      </AuthProvider>
    </BrowserRouter>
  );
}
```

---

## Login Page (Client-Hosted)

If the developer hosts their own login page:

```tsx
// src/pages/LoginPage.tsx
import React, { useState, useEffect } from 'react';
import { useSearchParams } from 'react-router-dom';
import axios from 'axios';
import { useAuth } from '../auth/AuthContext';

const APPTOR_REALM_URL = import.meta.env.VITE_APPTOR_REALM_URL;

function getRealmBaseUrl(): string {
  return APPTOR_REALM_URL.startsWith('http') ? APPTOR_REALM_URL : `https://${APPTOR_REALM_URL}`;
}

export function LoginPage() {
  const [searchParams] = useSearchParams();
  const { loginWithProvider } = useAuth();
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);

  const requestId = searchParams.get('request_id') || '';

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setLoading(true);
    setError('');

    try {
      // Call pre-authorize to validate credentials
      const params = new URLSearchParams({
        username,
        password,
        request_id: requestId,
      });

      const response = await axios.post(
        `${getRealmBaseUrl()}/oidc/pre-authorize`,
        params.toString(),
        { headers: { 'Content-Type': 'application/x-www-form-urlencoded' } }
      );

      if (response.data.preAuthToken) {
        // Exchange pre-auth token for authorization code
        const exchangeUrl =
          `${getRealmBaseUrl()}/oidc/auth` +
          `?request_id=${requestId}` +
          `&preAuthToken=${response.data.preAuthToken}`;
        window.location.href = exchangeUrl;
      }
    } catch (err: any) {
      setError(err.response?.data?.message || 'Login failed. Please check your credentials.');
    } finally {
      setLoading(false);
    }
  };

  const handleSocialLogin = (providerId: string) => {
    window.location.href =
      `${getRealmBaseUrl()}/oidc/auth` +
      `?provider_id=${providerId}` +
      `&request_id=${requestId}`;
  };

  return (
    <div style={{ maxWidth: '400px', margin: '4rem auto', padding: '2rem' }}>
      <h1>Sign In</h1>

      {error && <div style={{ color: 'red', marginBottom: '1rem' }}>{error}</div>}

      <form onSubmit={handleSubmit}>
        <div style={{ marginBottom: '1rem' }}>
          <label htmlFor="username">Email</label>
          <input
            id="username"
            type="email"
            value={username}
            onChange={(e) => setUsername(e.target.value)}
            required
            style={{ width: '100%', padding: '0.5rem' }}
          />
        </div>
        <div style={{ marginBottom: '1rem' }}>
          <label htmlFor="password">Password</label>
          <input
            id="password"
            type="password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            required
            style={{ width: '100%', padding: '0.5rem' }}
          />
        </div>
        <button type="submit" disabled={loading} style={{ width: '100%', padding: '0.75rem' }}>
          {loading ? 'Signing in...' : 'Sign In'}
        </button>
      </form>

      <div style={{ margin: '1.5rem 0', textAlign: 'center', color: '#666' }}>
        — or continue with —
      </div>

      <div style={{ display: 'flex', flexDirection: 'column', gap: '0.5rem' }}>
        {/* Render these based on configured IdPs */}
        <button onClick={() => handleSocialLogin('google')} style={{ padding: '0.75rem' }}>
          Sign in with Google
        </button>
        <button onClick={() => handleSocialLogin('microsoft')} style={{ padding: '0.75rem' }}>
          Sign in with Microsoft
        </button>
      </div>
    </div>
  );
}
```

---

## Social Login Buttons

Reusable social login button components:

```tsx
// src/components/SocialLoginButton.tsx
import React from 'react';

interface SocialLoginButtonProps {
  provider: 'google' | 'microsoft';
  onClick: (providerId: string) => void;
}

const providerConfig = {
  google: {
    label: 'Sign in with Google',
    bgColor: '#fff',
    textColor: '#333',
    borderColor: '#ddd',
    icon: '🔵', // Replace with actual SVG/icon
  },
  microsoft: {
    label: 'Sign in with Microsoft',
    bgColor: '#fff',
    textColor: '#333',
    borderColor: '#ddd',
    icon: '🟦', // Replace with actual SVG/icon
  },
};

export function SocialLoginButton({ provider, onClick }: SocialLoginButtonProps) {
  const config = providerConfig[provider];

  return (
    <button
      onClick={() => onClick(provider)}
      style={{
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        gap: '0.5rem',
        width: '100%',
        padding: '0.75rem',
        backgroundColor: config.bgColor,
        color: config.textColor,
        border: `1px solid ${config.borderColor}`,
        borderRadius: '4px',
        cursor: 'pointer',
        fontSize: '1rem',
      }}
    >
      <span>{config.icon}</span>
      <span>{config.label}</span>
    </button>
  );
}
```

---

## Token Refresh

Axios interceptor for automatic token refresh:

```typescript
// src/auth/apiClient.ts
import axios, { AxiosInstance, InternalAxiosRequestConfig, AxiosError } from 'axios';

const APPTOR_REALM_URL = import.meta.env.VITE_APPTOR_REALM_URL;
const APPTOR_CLIENT_ID = import.meta.env.VITE_APPTOR_CLIENT_ID;

function getRealmBaseUrl(): string {
  return APPTOR_REALM_URL.startsWith('http') ? APPTOR_REALM_URL : `https://${APPTOR_REALM_URL}`;
}

export function createAuthenticatedClient(baseURL: string): AxiosInstance {
  const client = axios.create({ baseURL });

  // Attach access token to every request
  client.interceptors.request.use((config: InternalAxiosRequestConfig) => {
    const token = sessionStorage.getItem('access_token');
    if (token) {
      config.headers.Authorization = `Bearer ${token}`;
    }
    return config;
  });

  // On 401, try to refresh the token
  client.interceptors.response.use(
    (response) => response,
    async (error: AxiosError) => {
      const originalRequest = error.config as any;

      if (error.response?.status === 401 && !originalRequest._retry) {
        originalRequest._retry = true;

        const refreshToken = sessionStorage.getItem('refresh_token');
        if (!refreshToken) {
          // No refresh token — redirect to login
          window.location.href = '/auth/login';
          return Promise.reject(error);
        }

        try {
          const params = new URLSearchParams({
            grant_type: 'refresh_token',
            refresh_token: refreshToken,
            client_id: APPTOR_CLIENT_ID,
          });

          const response = await axios.post(
            `${getRealmBaseUrl()}/oidc/token`,
            params.toString(),
            { headers: { 'Content-Type': 'application/x-www-form-urlencoded' } }
          );

          const { access_token, refresh_token: newRefreshToken } = response.data;
          sessionStorage.setItem('access_token', access_token);
          if (newRefreshToken) {
            sessionStorage.setItem('refresh_token', newRefreshToken);
          }

          // Retry the original request with new token
          originalRequest.headers.Authorization = `Bearer ${access_token}`;
          return client(originalRequest);
        } catch (refreshError) {
          // Refresh failed — redirect to login
          sessionStorage.removeItem('access_token');
          sessionStorage.removeItem('id_token');
          sessionStorage.removeItem('refresh_token');
          window.location.href = '/auth/login';
          return Promise.reject(refreshError);
        }
      }

      return Promise.reject(error);
    }
  );

  return client;
}

// Usage:
// const api = createAuthenticatedClient('https://api.yourapp.com');
// const data = await api.get('/users');
```
