# Python FastAPI — apptorID Integration Templates

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
pip install fastapi uvicorn httpx python-jose[cryptography] pydantic pydantic-settings
```

Or in `requirements.txt`:
```
fastapi>=0.100.0
uvicorn>=0.23.0
httpx>=0.24.0
python-jose[cryptography]>=3.3.0
pydantic>=2.0.0
pydantic-settings>=2.0.0
```

---

## Configuration

### .env (Single-Tenant)
```env
APPTOR_REALM_URL=acme-x1y2.sandbox.auth.apptor.io
APPTOR_CLIENT_ID=your-client-id
APPTOR_CLIENT_SECRET=your-client-secret
APP_BASE_URL=http://localhost:8000
APPTOR_REDIRECT_URI=http://localhost:8000/auth/callback
APPTOR_SCOPES=openid email profile
SECRET_KEY=your-secure-session-secret
POST_LOGIN_PATH=/dashboard
POST_LOGOUT_PATH=/
```

### config.py
```python
from pydantic_settings import BaseSettings


class ApptorAuthSettings(BaseSettings):
    apptor_realm_url: str
    apptor_client_id: str
    apptor_client_secret: str
    app_base_url: str
    apptor_redirect_uri: str
    apptor_scopes: str = "openid email profile"
    secret_key: str
    post_login_path: str = "/dashboard"
    post_logout_path: str = "/"

    @property
    def realm_base_url(self) -> str:
        url = self.apptor_realm_url
        return url if url.startswith("http") else f"https://{url}"

    @property
    def discovery_url(self) -> str:
        return f"{self.realm_base_url}/.well-known/openid-configuration"

    class Config:
        env_file = ".env"


settings = ApptorAuthSettings()
```

---

## OIDC Client Service

```python
from typing import Any
import httpx
from config import settings


class ApptorOidcClient:
    def __init__(self):
        self._discovery: dict[str, Any] | None = None

    async def initialize(self) -> None:
        """Fetch and cache the OIDC discovery document."""
        async with httpx.AsyncClient() as client:
            response = await client.get(settings.discovery_url)
            response.raise_for_status()
            self._discovery = response.json()
            print(f"apptorID discovery loaded from {settings.discovery_url}")

    @property
    def discovery(self) -> dict[str, Any]:
        if not self._discovery:
            raise RuntimeError("OIDC client not initialized. Call initialize() first.")
        return self._discovery

    @property
    def authorization_endpoint(self) -> str:
        return self.discovery["authorization_endpoint"]

    @property
    def token_endpoint(self) -> str:
        return self.discovery["token_endpoint"]

    @property
    def userinfo_endpoint(self) -> str:
        return self.discovery["userinfo_endpoint"]

    @property
    def jwks_uri(self) -> str:
        return self.discovery["jwks_uri"]

    @property
    def end_session_endpoint(self) -> str:
        return self.discovery["end_session_endpoint"]

    @property
    def issuer(self) -> str:
        return self.discovery["issuer"]

    def build_authorization_url(self, state: str, nonce: str) -> str:
        """Build the authorization URL for redirecting to apptorID.
        Backend apps: no PKCE needed — client_secret authenticates the token exchange.
        """
        params = {
            "client_id": settings.apptor_client_id,
            "redirect_uri": settings.apptor_redirect_uri,
            "response_type": "code",
            "scope": settings.apptor_scopes,
            "state": state,
            "nonce": nonce,
        }
        query = "&".join(f"{k}={v}" for k, v in params.items())
        return f"{self.authorization_endpoint}?{query}"

    async def exchange_code_for_tokens(self, code: str) -> dict[str, Any]:
        """Exchange an authorization code for tokens using client_secret (backend flow).
        client_secret comes from env var APPTOR_CLIENT_SECRET — never exposed to browser.
        """
        data = {
            "grant_type": "authorization_code",
            "code": code,
            "client_id": settings.apptor_client_id,
            "client_secret": settings.apptor_client_secret,
            "redirect_uri": settings.apptor_redirect_uri,
        }
        async with httpx.AsyncClient() as client:
            response = await client.post(
                self.token_endpoint,
                data=data,
                headers={"Content-Type": "application/x-www-form-urlencoded"},
            )
            response.raise_for_status()
            return response.json()

    async def refresh_token(self, refresh_token: str) -> dict[str, Any]:
        """Refresh an access token."""
        data = {
            "grant_type": "refresh_token",
            "refresh_token": refresh_token,
            "client_id": settings.apptor_client_id,
            "client_secret": settings.apptor_client_secret,
        }
        async with httpx.AsyncClient() as client:
            response = await client.post(
                self.token_endpoint,
                data=data,
                headers={"Content-Type": "application/x-www-form-urlencoded"},
            )
            response.raise_for_status()
            return response.json()

    async def get_user_info(self, access_token: str) -> dict[str, Any]:
        """Fetch user info using an access token."""
        async with httpx.AsyncClient() as client:
            response = await client.get(
                self.userinfo_endpoint,
                headers={"Authorization": f"Bearer {access_token}"},
            )
            response.raise_for_status()
            return response.json()

    def build_logout_url(self, post_logout_redirect_uri: str) -> str:
        """Build the logout URL."""
        return f"{self.end_session_endpoint}?post_logout_redirect_uri={post_logout_redirect_uri}"


oidc_client = ApptorOidcClient()
```

---

## PKCE Utility

```python
import hashlib
import base64
import secrets


def generate_code_verifier() -> str:
    """Generate a cryptographically random code verifier."""
    return secrets.token_urlsafe(64)


def generate_code_challenge(verifier: str) -> str:
    """Generate code challenge from verifier using S256 method."""
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    return base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")


def generate_secure_random() -> str:
    """Generate a secure random string for state/nonce."""
    return secrets.token_urlsafe(32)
```

---

## Auth Routes

```python
from fastapi import APIRouter, Request, HTTPException
from fastapi.responses import RedirectResponse
from starlette.middleware.sessions import SessionMiddleware

from oidc_client import oidc_client
from config import settings
from pkce import generate_secure_random

auth_router = APIRouter(prefix="/auth", tags=["auth"])


@auth_router.get("/login")
async def login(request: Request) -> RedirectResponse:
    """Initiates OAuth2 Authorization Code flow.
    Backend apps use client_secret for token exchange — no PKCE needed.
    """
    state = generate_secure_random()
    nonce = generate_secure_random()

    # Store in session
    request.session["oauth_state"] = state
    request.session["oauth_nonce"] = nonce

    auth_url = oidc_client.build_authorization_url(state, nonce)
    return RedirectResponse(url=auth_url)


@auth_router.get("/callback")
async def callback(request: Request, code: str, state: str) -> RedirectResponse:
    """Handles OAuth2 redirect. Receives ?code=xxx&state=xxx,
    validates state, exchanges code for tokens using client_id + client_secret
    (from env var APPTOR_CLIENT_SECRET), stores tokens in session,
    and redirects to dashboard.
    """
    # 1. Validate state (CSRF protection)
    saved_state = request.session.get("oauth_state")
    if not saved_state or saved_state != state:
        raise HTTPException(status_code=403, detail="Invalid state — possible CSRF attack")

    # 2. Exchange code for tokens using client_secret on the backend
    tokens = await oidc_client.exchange_code_for_tokens(code)

    # 3. Store tokens in session
    request.session["access_token"] = tokens["access_token"]
    request.session["id_token"] = tokens["id_token"]
    if "refresh_token" in tokens:
        request.session["refresh_token"] = tokens["refresh_token"]

    # 4. Clean up state
    request.session.pop("oauth_state", None)
    request.session.pop("oauth_nonce", None)

    # 5. Redirect to dashboard
    return RedirectResponse(url=settings.post_login_path)


@auth_router.get("/refresh")
async def refresh(request: Request) -> RedirectResponse:
    """Refreshes the access token."""
    refresh_token = request.session.get("refresh_token")
    if not refresh_token:
        return RedirectResponse(url="/auth/login")

    try:
        tokens = await oidc_client.refresh_token(refresh_token)
        request.session["access_token"] = tokens["access_token"]
        if "refresh_token" in tokens:
            request.session["refresh_token"] = tokens["refresh_token"]
    except Exception:
        return RedirectResponse(url="/auth/login")

    return_to = request.session.get("last_page", settings.post_login_path)
    return RedirectResponse(url=return_to)


@auth_router.get("/logout")
async def logout(request: Request) -> RedirectResponse:
    """Clears session and redirects to apptorID logout."""
    logout_url = oidc_client.build_logout_url(settings.post_logout_path)
    request.session.clear()
    return RedirectResponse(url=logout_url)


@auth_router.get("/me")
async def me(request: Request) -> dict:
    """Returns authenticated user's info."""
    access_token = request.session.get("access_token")
    if not access_token:
        raise HTTPException(status_code=401, detail="Not authenticated")
    return await oidc_client.get_user_info(access_token)
```

### App Setup

```python
from contextlib import asynccontextmanager
from fastapi import FastAPI
from starlette.middleware.sessions import SessionMiddleware

from config import settings
from oidc_client import oidc_client
from auth_routes import auth_router
from auth_middleware import require_auth


@asynccontextmanager
async def lifespan(app: FastAPI):
    await oidc_client.initialize()
    yield


app = FastAPI(lifespan=lifespan)
app.add_middleware(SessionMiddleware, secret_key=settings.secret_key)
app.include_router(auth_router)


# Protected routes example
@app.get("/dashboard")
async def dashboard(user=Depends(require_auth)):
    return {"message": f"Welcome, {user.get('name', user['sub'])}!"}
```

---

## Auth Middleware

```python
from typing import Any
from fastapi import Depends, HTTPException, Request
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from jose import jwt, JWTError
import httpx

from oidc_client import oidc_client

_jwks_cache: dict[str, Any] | None = None


async def _get_jwks() -> dict[str, Any]:
    """Fetch and cache JWKS from apptorID."""
    global _jwks_cache
    if _jwks_cache is None:
        async with httpx.AsyncClient() as client:
            response = await client.get(oidc_client.jwks_uri)
            response.raise_for_status()
            _jwks_cache = response.json()
    return _jwks_cache


async def _validate_token(token: str) -> dict[str, Any]:
    """Validate a JWT token against apptorID's JWKS."""
    jwks = await _get_jwks()
    try:
        unverified_header = jwt.get_unverified_header(token)
        kid = unverified_header.get("kid")
        key = next((k for k in jwks["keys"] if k["kid"] == kid), None)
        if not key:
            raise HTTPException(status_code=401, detail="Invalid token signing key")

        payload = jwt.decode(
            token,
            key,
            algorithms=["RS256"],
            issuer=oidc_client.issuer,
            options={"verify_aud": False},
        )
        return payload
    except JWTError as e:
        raise HTTPException(status_code=401, detail=f"Invalid token: {e}")


bearer_scheme = HTTPBearer(auto_error=False)


async def require_auth(
    request: Request,
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer_scheme),
) -> dict[str, Any]:
    """
    Dependency: requires authentication via Bearer token or session.
    Returns the decoded JWT claims.
    """
    # Try Bearer token first (API clients)
    if credentials:
        return await _validate_token(credentials.credentials)

    # Try session token (web app)
    access_token = request.session.get("access_token")
    if access_token:
        try:
            claims = await _validate_token(access_token)
            request.session["last_page"] = str(request.url.path)
            return claims
        except HTTPException:
            # Token expired — caller should redirect to /auth/refresh
            raise HTTPException(status_code=401, detail="Token expired")

    raise HTTPException(status_code=401, detail="Authentication required")


def require_roles(*roles: str):
    """
    Dependency factory: requires the user to have specific roles.
    Usage: @app.get("/admin", dependencies=[Depends(require_roles("admin"))])
    """
    async def _check_roles(claims: dict = Depends(require_auth)):
        user_roles = claims.get("roles", [])
        if not any(r in user_roles for r in roles):
            raise HTTPException(
                status_code=403,
                detail=f"Requires one of: {', '.join(roles)}",
            )
        return claims
    return _check_roles
```

---

## Client-Hosted Login Routes

```python
from fastapi import APIRouter
import httpx
from config import settings

client_login_router = APIRouter(prefix="/auth", tags=["client-login"])


@client_login_router.post("/pre-authorize")
async def pre_authorize(request: Request):
    """Validates credentials via apptorID pre-authorize endpoint."""
    body = await request.json()

    data = {
        "username": body["username"],
        "password": body["password"],
        "request_id": body["requestId"],
    }

    async with httpx.AsyncClient() as client:
        response = await client.post(
            f"{settings.realm_base_url}/oidc/pre-authorize",
            data=data,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )

    result = response.json()
    if "preAuthToken" in result:
        exchange_url = (
            f"{settings.realm_base_url}/oidc/auth"
            f"?request_id={body['requestId']}"
            f"&preAuthToken={result['preAuthToken']}"
        )
        return {"redirectUrl": exchange_url}

    raise HTTPException(status_code=401, detail="Authentication failed")


@client_login_router.get("/social/{provider_id}")
async def social_login(provider_id: str, request_id: str):
    """Redirects to external IdP via apptorID."""
    social_url = (
        f"{settings.realm_base_url}/oidc/auth"
        f"?provider_id={provider_id}"
        f"&request_id={request_id}"
    )
    return RedirectResponse(url=social_url)
```

---

## Multi-Tenant Resolver

```python
from fastapi import Request, HTTPException


async def resolve_tenant(request: Request, config_repository) -> dict:
    """
    Resolves the current tenant's apptorID config from the request.
    Adapt the resolution strategy to your tenancy model.
    """
    # Strategy 1: Subdomain
    host = request.headers.get("host", "")
    if "." in host:
        subdomain = host.split(".")[0]
        config = await config_repository.find_by_identifier(subdomain)
        if config:
            return config

    # Strategy 2: Header
    tenant_id = request.headers.get("x-tenant-id")
    if tenant_id:
        config = await config_repository.find_by_org_id(tenant_id)
        if config:
            return config

    # Strategy 3: Session
    org_id = request.session.get("org_id")
    if org_id:
        config = await config_repository.find_by_org_id(org_id)
        if config:
            return config

    raise HTTPException(status_code=400, detail="Cannot resolve tenant from request")
```

See `references/multitenant-db.md` for the database schema and SQLAlchemy models.
