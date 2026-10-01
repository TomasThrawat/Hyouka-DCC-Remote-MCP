#!/usr/bin/env python3

from __future__ import annotations

import os

import jwt
from aiohttp import ClientSession, ClientTimeout, web
from jwt import PyJWKClient

TEAM_SLUG = os.environ.get("VERCEL_OIDC_TEAM_SLUG", "hyouka1")
PROJECT_NAME = os.environ.get(
    "VERCEL_OIDC_PROJECT",
    "hyouka-free-game-engine-mcp",
)
ENVIRONMENT = os.environ.get("VERCEL_OIDC_ENVIRONMENT", "production")

ISSUER = f"https://oidc.vercel.com/{TEAM_SLUG}"
AUDIENCE = f"https://vercel.com/{TEAM_SLUG}"
SUBJECT = f"owner:{TEAM_SLUG}:project:{PROJECT_NAME}:environment:{ENVIRONMENT}"
JWKS_URL = f"{ISSUER}/.well-known/jwks"

UPSTREAM_URL = os.environ.get("UPSTREAM_URL", "http://127.0.0.1:10001").rstrip("/")
PORT = int(os.environ.get("PORT", "10000"))

_jwks = PyJWKClient(JWKS_URL)
_timeout = ClientTimeout(total=None)


def validate_token(request: web.Request) -> None:
    authorization = request.headers.get("Authorization", "")
    if not authorization.startswith("Bearer "):
        raise web.HTTPUnauthorized(
            text="Unauthorized",
            headers={"WWW-Authenticate": "Bearer"},
        )

    token = authorization[len("Bearer "):].strip()
    if not token:
        raise web.HTTPUnauthorized(
            text="Unauthorized",
            headers={"WWW-Authenticate": "Bearer"},
        )

    try:
        key = _jwks.get_signing_key_from_jwt(token)
        jwt.decode(
            token,
            key.key,
            algorithms=["RS256"],
            issuer=ISSUER,
            audience=AUDIENCE,
            subject=SUBJECT,
        )
    except Exception:
        raise web.HTTPUnauthorized(
            text="Unauthorized",
            headers={"WWW-Authenticate": "Bearer"},
        )


def forwarded_headers(request: web.Request) -> dict[str, str]:
    hop_by_hop = {
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade",
        "host",
        "content-length",
        "authorization",
    }
    return {
        key: value
        for key, value in request.headers.items()
        if key.lower() not in hop_by_hop
    }


async def proxy(request: web.Request) -> web.StreamResponse:
    validate_token(request)

    target = UPSTREAM_URL + request.path_qs
    body = await request.read()

    async with ClientSession(timeout=_timeout) as session:
        async with session.request(
            request.method,
            target,
            headers=forwarded_headers(request),
            data=body,
            allow_redirects=False,
        ) as upstream:
            response = web.StreamResponse(
                status=upstream.status,
                headers={
                    key: value
                    for key, value in upstream.headers.items()
                    if key.lower()
                    not in {
                        "connection",
                        "keep-alive",
                        "proxy-authenticate",
                        "proxy-authorization",
                        "te",
                        "trailer",
                        "transfer-encoding",
                        "upgrade",
                        "content-length",
                    }
                },
            )
            await response.prepare(request)

            async for chunk in upstream.content.iter_chunked(65536):
                await response.write(chunk)

            await response.write_eof()
            return response


def make_app() -> web.Application:
    app = web.Application()
    app.router.add_route("*", "/{path:.*}", proxy)
    return app


if __name__ == "__main__":
    web.run_app(make_app(), host="0.0.0.0", port=PORT)
