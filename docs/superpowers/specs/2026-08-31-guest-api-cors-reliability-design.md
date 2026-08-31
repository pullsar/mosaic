# Guest API CORS Reliability Design

## Problem

The production Flutter web client loads from `https://mixli.app` and calls the API at
`https://api.mixli.app`. The API correctly rejects browser origins that are not in its
explicit allowlist, but the production Compose contract does not inject any default
allowlist. Browser preflight for guest actor registration therefore returns `403`
before `/v1/feed` can run, even while health, topics, and catalog checks remain green.

## Decision

Production Compose supplies an overrideable `MOSAIC_WEB_ORIGINS` value to every API
replica. Its production default is the exact apex and `www` HTTPS origins:

```text
https://mixli.app,https://www.mixli.app
```

The API's existing exact-origin validation remains unchanged. Operators may override
the value for another deployment through the root-owned production environment file.
No wildcard origin, reflected origin, credentials mode, or same-origin proxy is added.

## Verification

The Compose contract test requires all four API replicas to receive the exact default
allowlist. The production verifier sends an `OPTIONS` request that matches Flutter
web's actor-registration preflight, including the requested `POST` method and
`content-type,authorization` headers. It accepts only a successful response whose
`Access-Control-Allow-Origin` equals `https://mixli.app` and whose allow-headers cover
both required headers.

The browser preflight check runs through both the direct origin verification path and
the public Cloudflare path. Deployment therefore fails before or immediately after a
traffic switch if browser guest access is not usable, while ordinary non-browser API
clients remain unaffected.

## Scope

This change does not alter feed ranking, actor credentials, Play documents, catalog
seeding, Cloudflare DNS, or the Flutter guest UI. It restores the existing guest data
flow and adds deployment evidence for that flow's browser boundary.
