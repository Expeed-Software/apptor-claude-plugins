# Angular Frontend — apptorID Integration Templates

## Table of Contents
1. [Dependencies](#dependencies)
2. [Environment Config](#environment-config)
3. [Auth Service](#auth-service)
4. [Auth Guard](#auth-guard)
5. [Auth Callback Component](#auth-callback-component)
6. [HTTP Interceptor](#http-interceptor)
7. [Login Component (Client-Hosted)](#login-component-client-hosted)

---

## Dependencies

```bash
npm install @auth0/angular-jwt
# or use the built-in HttpClient — no extra deps needed for basic flow
```

---

## Environment Config

```typescript
// src/environments/environment.ts
export const environment = {
  production: false,
  apptorRealmUrl: 'https://acme-x1y2.sandbox.auth.apptor.io',
  apptorClientId: 'your-client-id',
  redirectUri: 'http://localhost:4200/auth/callback',
  scopes: 'openid email profile',
  postLoginPath: '/dashboard',
  postLogoutPath: '/',
};
```

---

## Auth Service

```typescript
// src/app/auth/auth.service.ts
import { Injectable } from '@angular/core';
import { HttpClient, HttpParams } from '@angular/common/http';
import { Router } from '@angular/router';
import { BehaviorSubject, Observable } from 'rxjs';
import { environment } from '../../environments/environment';

interface User {
  sub: string;
  email: string;
  name: string;
  roles: string[];
  [key: string]: any;
}

interface TokenResponse {
  access_token: string;
  id_token: string;
  refresh_token?: string;
  expires_in: number;
}

@Injectable({ providedIn: 'root' })
export class AuthService {
  private userSubject = new BehaviorSubject<User | null>(null);
  user$ = this.userSubject.asObservable();

  constructor(private http: HttpClient, private router: Router) {
    this.loadFromStorage();
  }

  get isAuthenticated(): boolean {
    return !!this.userSubject.value;
  }

  get accessToken(): string | null {
    return sessionStorage.getItem('access_token');
  }

  get user(): User | null {
    return this.userSubject.value;
  }

  /**
   * Initiate OAuth2 Authorization Code flow with PKCE.
   */
  async login(): Promise<void> {
    const state = this.generateSecureRandom();
    const nonce = this.generateSecureRandom();
    const codeVerifier = this.generateCodeVerifier();
    const codeChallenge = await this.generateCodeChallenge(codeVerifier);

    sessionStorage.setItem('oauth_state', state);
    sessionStorage.setItem('oauth_nonce', nonce);
    sessionStorage.setItem('pkce_verifier', codeVerifier);

    const params = new URLSearchParams({
      client_id: environment.apptorClientId,
      redirect_uri: environment.redirectUri,
      response_type: 'code',
      scope: environment.scopes,
      state,
      nonce,
      code_challenge: codeChallenge,
      code_challenge_method: 'S256',
    });

    window.location.href = `${environment.apptorRealmUrl}/oidc/auth?${params.toString()}`;
  }

  /**
   * Redirect to external IdP (Google, Microsoft).
   */
  loginWithProvider(providerId: string): void {
    const state = sessionStorage.getItem('oauth_state') || this.generateSecureRandom();
    sessionStorage.setItem('oauth_state', state);

    const params = new URLSearchParams({
      client_id: environment.apptorClientId,
      redirect_uri: environment.redirectUri,
      response_type: 'code',
      scope: environment.scopes,
      state,
      provider_id: providerId,
    });

    window.location.href = `${environment.apptorRealmUrl}/oidc/auth?${params.toString()}`;
  }

  /**
   * Handle the callback — exchange code for tokens.
   */
  async handleCallback(code: string, state: string): Promise<void> {
    const savedState = sessionStorage.getItem('oauth_state');
    if (savedState && savedState !== state) {
      throw new Error('Invalid state — possible CSRF attack');
    }

    const codeVerifier = sessionStorage.getItem('pkce_verifier');
    if (!codeVerifier) {
      throw new Error('Missing PKCE verifier — session may have expired');
    }

    const body = new HttpParams()
      .set('grant_type', 'authorization_code')
      .set('code', code)
      .set('client_id', environment.apptorClientId)
      .set('redirect_uri', environment.redirectUri)
      .set('code_verifier', codeVerifier);

    const tokens = await this.http
      .post<TokenResponse>(`${environment.apptorRealmUrl}/oidc/token`, body.toString(), {
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      })
      .toPromise();

    if (tokens) {
      this.storeTokens(tokens);
    }

    // Clean up
    sessionStorage.removeItem('oauth_state');
    sessionStorage.removeItem('oauth_nonce');
    sessionStorage.removeItem('pkce_verifier');
  }

  /**
   * Refresh the access token.
   */
  async refreshAccessToken(): Promise<string | null> {
    const refreshToken = sessionStorage.getItem('refresh_token');
    if (!refreshToken) return null;

    try {
      const body = new HttpParams()
        .set('grant_type', 'refresh_token')
        .set('refresh_token', refreshToken)
        .set('client_id', environment.apptorClientId);

      const tokens = await this.http
        .post<TokenResponse>(`${environment.apptorRealmUrl}/oidc/token`, body.toString(), {
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        })
        .toPromise();

      if (tokens) {
        this.storeTokens(tokens);
        return tokens.access_token;
      }
    } catch {
      this.logout();
    }
    return null;
  }

  /**
   * Logout — clear session and redirect to apptorID logout.
   */
  logout(): void {
    sessionStorage.removeItem('access_token');
    sessionStorage.removeItem('id_token');
    sessionStorage.removeItem('refresh_token');
    this.userSubject.next(null);

    const logoutUrl = `${environment.apptorRealmUrl}/oidc/logout?post_logout_redirect_uri=${encodeURIComponent(window.location.origin + environment.postLogoutPath)}`;
    window.location.href = logoutUrl;
  }

  private storeTokens(tokens: TokenResponse): void {
    sessionStorage.setItem('access_token', tokens.access_token);
    sessionStorage.setItem('id_token', tokens.id_token);
    if (tokens.refresh_token) {
      sessionStorage.setItem('refresh_token', tokens.refresh_token);
    }

    const payload = this.parseJwt(tokens.access_token);
    this.userSubject.next({
      sub: payload.sub,
      email: payload.email,
      name: payload.name || payload.given_name || payload.email,
      roles: payload.roles || [],
      ...payload,
    });
  }

  private loadFromStorage(): void {
    const token = sessionStorage.getItem('access_token');
    if (token) {
      try {
        const payload = this.parseJwt(token);
        if (payload.exp * 1000 > Date.now()) {
          this.userSubject.next({
            sub: payload.sub,
            email: payload.email,
            name: payload.name || payload.given_name || payload.email,
            roles: payload.roles || [],
            ...payload,
          });
        } else {
          sessionStorage.clear();
        }
      } catch {
        sessionStorage.clear();
      }
    }
  }

  private parseJwt(token: string): any {
    const base64Url = token.split('.')[1];
    const base64 = base64Url.replace(/-/g, '+').replace(/_/g, '/');
    return JSON.parse(atob(base64));
  }

  private generateSecureRandom(): string {
    const array = new Uint8Array(32);
    crypto.getRandomValues(array);
    return btoa(String.fromCharCode(...array)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  }

  private generateCodeVerifier(): string {
    const array = new Uint8Array(64);
    crypto.getRandomValues(array);
    return btoa(String.fromCharCode(...array)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  }

  private async generateCodeChallenge(verifier: string): Promise<string> {
    const encoder = new TextEncoder();
    const digest = await crypto.subtle.digest('SHA-256', encoder.encode(verifier));
    return btoa(String.fromCharCode(...new Uint8Array(digest))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  }
}
```

---

## Auth Guard

```typescript
// src/app/auth/auth.guard.ts
import { Injectable } from '@angular/core';
import { CanActivate, ActivatedRouteSnapshot, Router } from '@angular/router';
import { AuthService } from './auth.service';

@Injectable({ providedIn: 'root' })
export class AuthGuard implements CanActivate {
  constructor(private authService: AuthService, private router: Router) {}

  async canActivate(route: ActivatedRouteSnapshot): Promise<boolean> {
    if (!this.authService.isAuthenticated) {
      await this.authService.login();
      return false;
    }

    const requiredRoles = route.data['roles'] as string[] | undefined;
    if (requiredRoles) {
      const userRoles = this.authService.user?.roles || [];
      const hasRole = requiredRoles.some((r) => userRoles.includes(r));
      if (!hasRole) {
        this.router.navigate(['/forbidden']);
        return false;
      }
    }

    return true;
  }
}
```

### Routing Setup

```typescript
// src/app/app-routing.module.ts
const routes: Routes = [
  { path: '', component: HomeComponent },
  { path: 'auth/callback', component: AuthCallbackComponent },
  { path: 'dashboard', component: DashboardComponent, canActivate: [AuthGuard] },
  { path: 'admin', component: AdminComponent, canActivate: [AuthGuard], data: { roles: ['admin'] } },
];
```

---

## Auth Callback Component

```typescript
// src/app/auth/auth-callback.component.ts
import { Component, OnInit } from '@angular/core';
import { ActivatedRoute, Router } from '@angular/router';
import { AuthService } from './auth.service';
import { environment } from '../../environments/environment';

@Component({
  selector: 'app-auth-callback',
  template: `
    <div *ngIf="error" style="padding: 2rem; text-align: center;">
      <h2>Authentication Error</h2>
      <p style="color: red;">{{ error }}</p>
      <button (click)="authService.login()">Try Again</button>
    </div>
    <div *ngIf="!error" style="padding: 2rem; text-align: center;">
      <p>Completing authentication...</p>
    </div>
  `,
})
export class AuthCallbackComponent implements OnInit {
  error = '';

  constructor(
    private route: ActivatedRoute,
    private router: Router,
    public authService: AuthService
  ) {}

  async ngOnInit(): Promise<void> {
    const code = this.route.snapshot.queryParamMap.get('code');
    const state = this.route.snapshot.queryParamMap.get('state');

    if (!code) {
      this.error = 'Missing authorization code';
      return;
    }

    try {
      await this.authService.handleCallback(code, state || '');
      this.router.navigate([environment.postLoginPath], { replaceUrl: true });
    } catch (err: any) {
      this.error = err.message || 'Authentication failed';
    }
  }
}
```

---

## HTTP Interceptor

```typescript
// src/app/auth/auth.interceptor.ts
import { Injectable } from '@angular/core';
import { HttpInterceptor, HttpRequest, HttpHandler, HttpEvent, HttpErrorResponse } from '@angular/common/http';
import { Observable, throwError, from } from 'rxjs';
import { catchError, switchMap } from 'rxjs/operators';
import { AuthService } from './auth.service';

@Injectable()
export class AuthInterceptor implements HttpInterceptor {
  private isRefreshing = false;

  constructor(private authService: AuthService) {}

  intercept(req: HttpRequest<any>, next: HttpHandler): Observable<HttpEvent<any>> {
    // Don't intercept auth-related requests
    if (req.url.includes('/oidc/')) {
      return next.handle(req);
    }

    const token = this.authService.accessToken;
    const authReq = token
      ? req.clone({ setHeaders: { Authorization: `Bearer ${token}` } })
      : req;

    return next.handle(authReq).pipe(
      catchError((error: HttpErrorResponse) => {
        if (error.status === 401 && !this.isRefreshing) {
          this.isRefreshing = true;
          return from(this.authService.refreshAccessToken()).pipe(
            switchMap((newToken) => {
              this.isRefreshing = false;
              if (newToken) {
                const retryReq = req.clone({
                  setHeaders: { Authorization: `Bearer ${newToken}` },
                });
                return next.handle(retryReq);
              }
              return throwError(() => error);
            }),
            catchError((refreshError) => {
              this.isRefreshing = false;
              this.authService.logout();
              return throwError(() => refreshError);
            })
          );
        }
        return throwError(() => error);
      })
    );
  }
}
```

### Register the Interceptor

```typescript
// src/app/app.module.ts
import { HTTP_INTERCEPTORS } from '@angular/common/http';
import { AuthInterceptor } from './auth/auth.interceptor';

@NgModule({
  providers: [
    { provide: HTTP_INTERCEPTORS, useClass: AuthInterceptor, multi: true },
  ],
})
export class AppModule {}
```

---

## Login Component (Client-Hosted)

```typescript
// src/app/auth/login.component.ts
import { Component } from '@angular/core';
import { ActivatedRoute } from '@angular/router';
import { HttpClient } from '@angular/common/http';
import { environment } from '../../environments/environment';

@Component({
  selector: 'app-login',
  template: `
    <div style="max-width: 400px; margin: 4rem auto; padding: 2rem;">
      <h1>Sign In</h1>

      <div *ngIf="error" style="color: red; margin-bottom: 1rem;">{{ error }}</div>

      <form (ngSubmit)="onSubmit()">
        <div style="margin-bottom: 1rem;">
          <label for="username">Email</label>
          <input id="username" type="email" [(ngModel)]="username" name="username"
                 required style="width: 100%; padding: 0.5rem;" />
        </div>
        <div style="margin-bottom: 1rem;">
          <label for="password">Password</label>
          <input id="password" type="password" [(ngModel)]="password" name="password"
                 required style="width: 100%; padding: 0.5rem;" />
        </div>
        <button type="submit" [disabled]="loading" style="width: 100%; padding: 0.75rem;">
          {{ loading ? 'Signing in...' : 'Sign In' }}
        </button>
      </form>

      <div style="margin: 1.5rem 0; text-align: center; color: #666;">— or continue with —</div>

      <div style="display: flex; flex-direction: column; gap: 0.5rem;">
        <button (click)="socialLogin('google')" style="padding: 0.75rem;">Sign in with Google</button>
        <button (click)="socialLogin('microsoft')" style="padding: 0.75rem;">Sign in with Microsoft</button>
      </div>
    </div>
  `,
})
export class LoginComponent {
  username = '';
  password = '';
  error = '';
  loading = false;
  requestId = '';

  constructor(private route: ActivatedRoute, private http: HttpClient) {
    this.requestId = this.route.snapshot.queryParamMap.get('request_id') || '';
  }

  async onSubmit(): Promise<void> {
    this.loading = true;
    this.error = '';

    const body = new URLSearchParams({
      username: this.username,
      password: this.password,
      request_id: this.requestId,
    });

    try {
      const response = await this.http
        .post<any>(`${environment.apptorRealmUrl}/oidc/pre-authorize`, body.toString(), {
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        })
        .toPromise();

      if (response?.preAuthToken) {
        window.location.href =
          `${environment.apptorRealmUrl}/oidc/auth` +
          `?request_id=${this.requestId}` +
          `&preAuthToken=${response.preAuthToken}`;
      }
    } catch (err: any) {
      this.error = err.error?.message || 'Login failed';
    } finally {
      this.loading = false;
    }
  }

  socialLogin(providerId: string): void {
    window.location.href =
      `${environment.apptorRealmUrl}/oidc/auth` +
      `?provider_id=${providerId}` +
      `&request_id=${this.requestId}`;
  }
}
```
