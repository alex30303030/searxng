# SearXNG — patched fork

A fork of [SearXNG](https://github.com/searxng/searxng) that adds **optional
browser TLS fingerprint impersonation** to the outgoing HTTP client, plus fixes
for two engines that had stopped returning results.

Upstream's own README is [README.rst](README.rst); it still applies in full.
This file only describes what this fork adds.

## Why

A self-hosted instance was being CAPTCHA'd or refused by Brave, DuckDuckGo,
Startpage and Yahoo while Google, Bing and Wikipedia worked — identically from a
residential IP and from a proxied one, which ruled out IP reputation.

SearXNG's HTTP client is `httpx` over Python's OpenSSL bindings, which produces
a TLS handshake no browser produces. Bot management fingerprints that handshake
(JA3/JA4) and the HTTP/2 SETTINGS frame directly, below the HTTP layer, so no
User-Agent or proxy change affects it. This fork routes requests through
[`curl_cffi`](https://github.com/lexiforest/curl_cffi) via
[`httpx-curl-cffi`](https://github.com/vgavro/httpx-curl-cffi), which reproduces
a real browser's handshake.

That turned out to be **one** of the causes, not the only one — see Status.

## Status

Measured against a live instance built from this branch. `off` is stock
upstream behaviour; `on` is `outgoing.impersonate: chrome`.

| engine | off | on | what actually fixed it |
| --- | --- | --- | --- |
| brave | 0 — *too many requests* | **20 results** | TLS impersonation |
| duckduckgo | 0 — *CAPTCHA* | **10 results** | engine fix (GET + Referer) |
| yahoo | 0 — *HTTP protocol error* | **7 results** | engine fix (redirect + parser) |
| google | 10 results | 10 results | unchanged |
| bing | 10 results | 10 results | unchanged |
| wikipedia | 1 infobox | 1 infobox | unchanged |
| startpage | 0 — *CAPTCHA* | 0 — *blocked* | **not fixed** — see below |

Only **brave** was fixed by the impersonation itself. DuckDuckGo and Yahoo were
ordinary engine bugs that the work happened to uncover; both fixes are
independent of the transport and would apply to stock SearXNG.

Wikipedia returns an *infobox* rather than `results` — counting `results` reports
0 for a perfectly healthy engine.

### Not fixed

- **Startpage** is behind [Anubis](https://github.com/TecharoHQ/anubis), a
  JavaScript proof-of-work gate. The impersonated request gets a clean `200`
  and a challenge page whose metadata echoes our own User-Agent back, so the
  TLS work succeeds and the gate simply sits above it. Passing it means
  computing the proof-of-work, which is a policy decision rather than an
  engineering one, and is deliberately not implemented here.
- **Presearch** was removed upstream in `81b0ed7b3` (2026-07-29) because the
  service shut down. No transport change can bring it back.

## Configuration

Impersonation is **off by default**. With `outgoing.impersonate` unset,
behaviour is identical to upstream.

```yaml
outgoing:
  impersonate: chrome
```

Any profile `curl_cffi` supports is valid — `chrome`, `chrome136`, `firefox`,
`firefox147`, `safari`, `edge`, and so on. Pinning a version is worthwhile,
since bare `chrome` follows whatever curl_cffi's current default is.

It can also be set per network or per engine, which is useful because only some
engines need it:

```yaml
engines:
  - name: duckduckgo
    network:
      impersonate: chrome
```

### Proxies

`outgoing.proxies` keeps working, for HTTP(S) and SOCKS alike — verified live
against a residential proxy, with identical results on every engine.

**Use sticky sessions, not per-request rotation.** A rotating proxy gives every
request a different exit IP, which breaks any engine needing two requests from
the same address — DuckDuckGo's `vqd` and Startpage's `sc` token are both issued
*to the requesting IP*. Most providers expose stickiness through the credentials
(e.g. `password_session-<id>_lifetime-<minutes>`).

Keep proxy credentials in your deployed `settings.yml`, not in this repository.

## Build and deploy

Upstream's container build cannot be driven by `docker compose` directly:
`container/dist.dockerfile` starts `FROM localhost/searxng/searxng:builder`, an
image you must build and tag first. The [`Dockerfile`](Dockerfile) at the root
merges both upstream stages so the image builds in one step.

```bash
docker build -t searxng-curlcffi:latest .
```

**BuildKit is required** — `--mount=type=cache` and `COPY --exclude` are
inherited from upstream. On Docker 23+ that means the `buildx` component must be
installed, or `docker build` silently falls back to the legacy builder and fails
with `the --mount option requires BuildKit`.

Compose service block, assuming this fork is checked out beside the compose file:

```yaml
  searxng:
    build:
      context: ./searxng-src
      args:
        VERSION: "2026.7.29-curlcffi"
    image: searxng-curlcffi:latest
    restart: unless-stopped
    ports:
      - "8080:8080"
    volumes:
      - ./config/:/etc/searxng/:rw
      - searxng-data:/var/cache/searxng/
```

Enabling the patch is a `settings.yml` change, not an image change — the image
is inert until `outgoing.impersonate` is set.

## What changed

Ten commits, deliberately small and separable. Source changes are confined to
seven files; the transport patch itself is about 60 lines.

| area | files |
| --- | --- |
| dependency | `requirements.txt` |
| transport | `searx/network/client.py` |
| settings | `searx/network/network.py`, `searx/settings_defaults.py`, `searx/settings.yml` |
| engine fixes | `searx/engines/duckduckgo.py`, `searx/engines/yahoo.py` |
| packaging | `Dockerfile`, `NOTES.md`, `README.md` (new files) |

Three things are worth knowing before touching the transport code, all of which
are load-bearing and easy to undo by accident:

1. `shuffle_ciphers()` is deliberately **bypassed** on the impersonation path.
   It randomises cipher order to defeat fingerprinting, which would corrupt the
   browser profile being reproduced.
2. SOCKS proxies go through curl_cffi rather than `httpx_socks` when
   impersonating — `httpx_socks` terminates TLS in Python, discarding the
   impersonation.
3. `CurlOpt.FRESH_CONNECT` is mandatory, not an optimisation. SearXNG queries
   every engine in parallel, and concurrent requests through one curl transport
   interfere without it.

[NOTES.md](NOTES.md) has the full detail: per-engine measurements, the
fingerprint before/after, the rebase conflict map, and a record of one change
that was tried and reverted.

## Tracking upstream

`master` is kept pristine and tracking `upstream/master`; all work is on
`feat/curl-cffi-transport`. The `fork-base` tag marks the commit the patch was
written against.

```bash
git fetch upstream
git rebase upstream/master
```

The likeliest conflict is in `searx/network/client.py`, where two function
signatures were reflowed to multi-line to fit the new parameter. `Dockerfile` is
not a rebase conflict — upstream has no root Dockerfile — but it is a merged
copy of upstream's two container files and will drift silently, so re-check it
against them after every rebase.

After rebasing, re-run the fingerprint check before redeploying: a `curl_cffi`
or `httpx` bump can change the emitted profile.

## Caveat on the measurements

All engine results were measured from a single network location at one point in
time. Anti-bot behaviour is per-IP and time-varying — during testing, the test
traffic itself was enough to get engines to start refusing, and results moved
accordingly. Re-run the checks from your own deployment before drawing
conclusions, and prefer repeated samples over single observations.

## License

Unchanged from upstream: GNU AGPL-3.0-or-later. See [LICENSE](LICENSE).
