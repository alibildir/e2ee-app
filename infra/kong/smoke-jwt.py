#!/usr/bin/env python3
"""Kong JWT smoke test (SCA-19 Test Plan §4.4).

Mints an HS256 JWT that matches the Go backend's auth.IssueJWT shape
(Sprint 5 PR-32, ADV-3) and verifies it round-trips through Kong.

Pre-requisite: Kong + backend are running (Test Plan step 4.1), and the
infra/kong/kong.yml JWT plugin reads the same JWT_SECRET from the env
vault (KONG_PLUGINS includes 'jwt').

Exit code:
    0  all assertions pass
    1  any assertion fails
    2  missing dependency (pyjwt not installed, JWT_SECRET unset, ...)
"""
from __future__ import annotations

import argparse
import os
import sys
import time
from typing import Tuple

try:
    import jwt  # PyJWT
except ImportError:
    print("[FAIL] PyJWT not installed. Install with: pip install PyJWT", file=sys.stderr)
    sys.exit(2)


# Match infra/kong/kong.yml consumer entry:
#   consumers:
#     - username: opene2ee-mobile
#       jwt_secrets:
#         - key: opene2ee-backend        <-- JWT 'iss' claim MUST match
#           algorithm: HS256
#           secret: "{vault://env/jwt-secret}"
# Kong's HS256 plugin uses the 'iss' claim to look up the secret, so we
# MUST set iss='opene2ee-backend' (the 'key' field, not the username).
JWT_ISSUER = "opene2ee-backend"
JWT_AUDIENCE = "opene2ee-mobile"  # informational only; Kong HS256 does not verify aud
JWT_TTL_SEC = 300


def mint(secret: str, sub: str = "smoke-test-user", ttl: int = JWT_TTL_SEC) -> str:
    """Mint an HS256 JWT with the shape Kong's jwt plugin expects."""
    now = int(time.time())
    payload = {
        "iss": JWT_ISSUER,
        "aud": JWT_AUDIENCE,
        "sub": sub,
        "iat": now,
        "exp": now + ttl,
    }
    return jwt.encode(payload, secret, algorithm="HS256")


def http_get(url: str, token: str | None, timeout: float = 5.0) -> Tuple[int, str]:
    """Minimal HTTP GET without external deps; uses urllib so we don't
    need 'requests' on every contributor's host."""
    import urllib.request
    import urllib.error

    req = urllib.request.Request(url, method="GET")
    if token is not None:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode("utf-8", errors="replace") if exc.fp else ""
    except urllib.error.URLError as exc:
        print(f"[FAIL] Could not reach {url}: {exc.reason}", file=sys.stderr)
        sys.exit(2)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "--kong-url",
        default=os.environ.get("KONG_URL", "http://localhost:8000"),
        help="Kong proxy URL (default: $KONG_URL or http://localhost:8000)",
    )
    p.add_argument(
        "--whoami-path",
        default="/api/v1/auth/whoami",
        help="Path to a JWT-protected route that echoes the JWT claims "
             "(default: /api/v1/auth/whoami — Spring 5 PR-32 route table)",
    )
    p.add_argument(
        "--secret-env",
        default="JWT_SECRET",
        help="Env var name carrying the shared HS256 secret (default: JWT_SECRET). "
             "MUST match infra/docker-compose.yml kong + backend env.",
    )
    p.add_argument("--sub", default="smoke-test-user", help="JWT 'sub' claim value")
    return p.parse_args()


def main() -> int:
    args = parse_args()
    secret = os.environ.get(args.secret_env, "")
    if not secret:
        print(f"[FAIL] {args.secret_env} env var is empty. The Kong + backend "
              f"compose service sets it via ${{{args.secret_env}:?}}. Set it "
              f"before running this script.", file=sys.stderr)
        return 2

    url = args.kong_url.rstrip("/") + args.whoami_path

    # ---- Probe 1: no auth → 401 ----------------------------------------
    print(f"[1/3] no-auth probe  -> {url}")
    code, body = http_get(url, token=None)
    if code != 401:
        print(f"[FAIL] expected 401 without Authorization header, got {code}. "
              f"Body: {body[:200]}", file=sys.stderr)
        return 1
    print("       ok (401 — JWT plugin blocked unauthenticated request)")

    # ---- Probe 2: valid HS256 JWT → 200 -------------------------------
    token = mint(secret, sub=args.sub)
    print(f"[2/3] valid-JWT probe -> {url}  (sub={args.sub!r}, iss={JWT_ISSUER!r})")
    code, body = http_get(url, token=token)
    if code != 200:
        print(f"[FAIL] expected 200 with valid JWT, got {code}. "
              f"Body: {body[:200]}", file=sys.stderr)
        return 1
    print("       ok (200 — Kong accepted HS256 with iss='opene2ee-backend')")

    # ---- Probe 3: tampered signature → 401 ----------------------------
    # Flip the last char of the signature segment; HS256 will fail to
    # verify. Confirms the JWT plugin is actually validating, not just
    # checking presence of the Bearer header.
    head, payload, sig = token.split(".")
    tampered = ".".join([head, payload, sig[:-1] + ("A" if sig[-1] != "A" else "B")])
    print(f"[3/3] tampered-sig probe -> {url}")
    code, body = http_get(url, token=tampered)
    if code != 401:
        print(f"[FAIL] expected 401 with tampered signature, got {code}. "
              f"Body: {body[:200]}", file=sys.stderr)
        return 1
    print("       ok (401 — HS256 sig verification rejects tampered token)")

    print("\n[PASS] infra/kong/smoke-jwt.py: all 3 probes succeeded.")
    return 0


if __name__ == "__main__":
    sys.exit(main())