# Fork notes: browser TLS fingerprint impersonation

Branch: `feat/curl-cffi-transport`
Fork point: `upstream/master` at `a1144dda3` (2026-07-29), tagged `fork-base`.

## Why this fork exists

DuckDuckGo, Startpage, Brave and Presearch CAPTCHA or suspend this instance while
Google, Bing and Wikipedia work fine — identically from a residential IP and from
a proxied one, which rules out IP reputation.

The blocked engines sit behind bot management that fingerprints the **TLS
handshake itself**: the ClientHello's cipher/extension ordering (JA3/JA4) and the
HTTP/2 SETTINGS frame (Akamai hash). SearXNG's HTTP client is `httpx` over
Python's OpenSSL bindings, which produces a signature no real browser emits. No
User-Agent header or proxy changes that, because it is decided below the HTTP
layer.

The fix routes requests through `curl_cffi`, which links libcurl-impersonate and
reproduces a real browser's handshake byte-for-byte.

Note that upstream already has `shuffle_ciphers()` in `searx/network/client.py`,
which randomises cipher order to *avoid* matching a known-bad fingerprint. That
is a blocklist-evasion tactic; it does not make the client look like a browser,
and it is bypassed on the impersonation path (see below).

## What changed

Four commits, deliberately small and separable:

| Commit | File | Change |
| --- | --- | --- |
| `deps` | `requirements.txt` | add `httpx-curl-cffi==0.1.5` |
| `network` | `searx/network/client.py` | `get_impersonate_transport()` + delegation |
| `settings` | `searx/settings_defaults.py`, `searx/settings.yml`, `searx/network/network.py` | `outgoing.impersonate` key, threaded through |
| `docs` | `Dockerfile`, `NOTES.md` | self-contained image build |

### `searx/network/client.py` — the actual patch

* New `get_impersonate_transport()` returns an `AsyncCurlTransport`.
* `get_transport()` and `get_transport_for_socks_proxy()` each gained an
  `impersonate: str | None = None` parameter and return early to the new
  function when it is set. Both signatures were reflowed to multi-line because
  the added parameter pushed them past the line length limit — that reflow is
  the main rebase conflict risk in this file.
* `new_client()` gained the same parameter and forwards it at its three
  transport construction sites.

Four things worth knowing before touching this code:

1. **`shuffle_ciphers()` is deliberately bypassed.** The impersonation path
   builds no `SSLContext` at all. Shuffling ciphers would corrupt the very
   browser fingerprint being reproduced. If you ever make the impersonation path
   call `get_sslcontexts()`, you silently undo the whole patch.
2. **`verify` is passed as the raw bool/path**, not an `SSLContext` — curl_cffi
   rejects `SSLContext` objects. So `outgoing.verify: /path/to/ca.pem` still
   works, but a code path that hands it a context object will break.
3. **SOCKS proxies go through curl, not `httpx_socks`,** when impersonating.
   `httpx_socks` terminates TLS in Python, which would discard the
   impersonation. curl speaks SOCKS natively, so `socks5h://` keeps working.
4. **`CurlOpt.FRESH_CONNECT` is mandatory, not an optimisation.** Concurrent
   requests through one curl transport interfere without it, and SearXNG queries
   every engine in parallel on every search — this path is *always* concurrent.
   See <https://github.com/vgavro/httpx-curl-cffi>.

`http2`, `limits` and `retries` are accepted but ignored when impersonating: the
browser profile dictates ALPN, and `FRESH_CONNECT` disables pooling by design.

### Configuration

Off by default; unset means byte-for-byte upstream behaviour.

```yaml
outgoing:
  impersonate: chrome
```

Because the key lives in `initialize()`'s `default_params`, per-network and
per-engine overrides work without extra code:

```yaml
engines:
  - name: duckduckgo
    network:
      impersonate: chrome
```

Any profile curl_cffi supports is valid (`chrome`, `chrome131`, `firefox`,
`safari`, `edge`, ...). Pinning a specific version can be worthwhile, since bare
`chrome` tracks whatever curl_cffi's current default is.

## Verification

Measured against `https://tls.browserleaks.com/json` from **inside the built
container image** (CPython 3.14.7), through SearXNG's own `new_client()`:

| | stock httpx | `impersonate: chrome` |
| --- | --- | --- |
| JA3N | `5d4148aac0f16fa7a9405dc031cc87de` | `8e19337e7524d2573be54efb2b0784c9` |
| JA4 | `t13d1712h1_ab0a1bf427ad_8e6e362c5eac` | `t13d1516h2_8daaf6152771_806a8c22fdea` |
| Akamai (HTTP/2) | *(none)* | `52d84b11737d980aef856699f885ca86` |
| User-Agent | `python-httpx/0.28.1` | `Mozilla/5.0 ... Chrome/150.0.0.0 Safari/537.36` |

The "after" values reproduce exactly on the host venv too. The "before" values do
*not* reproduce exactly run-to-run — upstream's `shuffle_ciphers()` randomises
cipher order per `SSLContext`, so stock JA3N/JA4 drift between processes. That
drift is itself the problem: it is not any browser's fingerprint, just a moving
non-browser one. The `h1` vs `h2` in the JA4 prefix also shows stock httpx failing
to negotiate HTTP/2 here, while the impersonated client does.

Confirmed, going through SearXNG's own `new_client()`:

* **Proxy routing is preserved.** With `impersonate` unset the mounts are
  unchanged (`AsyncHTTPTransport` for HTTP(S), `AsyncProxyTransportFixed` for
  SOCKS). With it set, both become `AsyncCurlTransport`, and the
  `http:// -> AsyncHTTPTransportNoHttp` block still applies.
* **Concurrency is safe.** 10 parallel requests through one client on the host
  and 8 in the container: all succeeded, single stable JA4 in both.
* **The image builds and runs.** Built from this branch and exercised in the
  container, producing the "after" column above.
* **Stripping is safe.** The container build runs `strip --strip-unneeded`
  across the venv, which hits curl_cffi's bundled `_wrapper.abi3.so`
  (38MB -> 6.8MB). The impersonated JA4 is identical afterwards.
* **Python 3.14 is fine.** curl_cffi 0.16.3 publishes no `cp314` wheel, but its
  wheels are `cp310-abi3`, which install and run correctly on 3.14.

Raw JA3 (unnormalised) differs on every connection. That is expected and is not
a bug: Chrome uses GREASE and shuffles extension order, so real Chrome does the
same. Compare JA3N/JA4, never raw JA3.

### Unit tests

Full suite on this branch: **339 tests, OK** (`python -m nose2 -s tests/unit -t .`).

### Engine results — impersonation fixes one engine, not four

Two containers built from this branch, identical except `outgoing.impersonate`,
queried through the JSON API. This is the honest outcome, and it is narrower
than the premise the fork was built on:

| engine | stock httpx | `impersonate: chrome` | verdict |
| --- | --- | --- | --- |
| brave | 0 — *too many requests* | **20 results** | **fixed** |
| duckduckgo | 0 — *CAPTCHA* | 0 — *CAPTCHA* | not fixed |
| startpage | 0 — *CAPTCHA* | 0 — *JSONDecodeError* | block cleared, parser fails |
| yahoo | 0 — *HTTP protocol error* | 0 — no error | transport fixed, 0 results |
| google | 10 results | 10 results | no regression |
| bing | 10 results | 10 results | no regression |
| wikipedia | 1 infobox | 1 infobox | no regression |

Reading this correctly matters:

* **Brave is a clean win.** It was returning *too many requests* and now returns
  a full page of results.
* **DuckDuckGo is unaffected.** Still CAPTCHA on every profile tried (chrome,
  chrome136, firefox147, safari184). Whatever DDG is keying on, it is not the
  TLS fingerprint alone.
* **Startpage and Yahoo moved, but did not start working.** Impersonation
  cleared the *network-level* block and revealed a *second, unrelated* failure
  underneath — an engine/parser mismatch:
  * Startpage: `JSONDecodeError: Extra data` at `searx/engines/startpage.py:409`
    — the page is fetched fine, but the embedded JSON no longer parses.
  * Yahoo: no error at all, simply zero results across every query tried.

  Both are upstream engine-parser bugs against the sites' current markup. They
  need a separate fix and are not addressable from the transport layer.
* **Wikipedia returns an infobox, not `results`.** Measuring `len(results)` for
  it reports 0 on a working engine — do not mistake that for a regression.
* **Presearch is gone.** Upstream deleted the engine in `81b0ed7b3` (2026-07-29)
  "because it got shutdown". It is absent from this fork, and no transport
  change can bring it back.

So of the five engines this fork set out to fix: **1 fixed (brave), 1 untouched
(duckduckgo), 2 partially advanced but still broken for other reasons (startpage,
yahoo), 1 impossible (presearch, service dead).** Nothing regressed.

### Caveat on these results

They were measured from a single IP that is neither the residential nor the
proxied address the original diagnosis used. Anti-bot behaviour is per-IP and
time-varying, so DuckDuckGo in particular may behave differently from the
deployment host. Re-run the matrix there before drawing final conclusions.

## Rebasing onto upstream

```bash
git fetch upstream
git rebase upstream/master
```

Conflict hotspots, in likelihood order:

1. `searx/network/client.py` — the reflowed `get_transport()` /
   `get_transport_for_socks_proxy()` signatures. If upstream also touches them,
   take upstream's and re-add the `impersonate` parameter and the early return.
2. `requirements.txt` — trivial, adjacent-line conflicts only.
3. `searx/network/network.py` — `__slots__`, `__init__`, `get_client()` and
   `initialize()`'s `default_params` each gained one line.
4. `Dockerfile` — not a rebase conflict (upstream has no root Dockerfile), but
   **re-check it against `container/builder.dockerfile` and
   `container/dist.dockerfile` after every rebase**, since it is a merged copy
   of both and will drift silently.

After rebasing, re-run the fingerprint check before redeploying — a curl_cffi or
httpx bump can change the emitted profile.

## Deployment

The image builds from this branch in one step (upstream's own dockerfiles cannot,
since `dist.dockerfile` starts `FROM localhost/searxng/searxng:builder`):

```bash
docker build -t searxng-curlcffi:latest .
```

**BuildKit is required.** The Dockerfile inherits `--mount=type=cache` and
`COPY --exclude` from upstream, both of which are BuildKit-only. On Docker 23+
that means the `buildx` component must be installed — without it `docker build`
silently falls back to the legacy builder and fails with
`the --mount option requires BuildKit`. On Arch: `pacman -S docker-buildx`.

`.dockerignore` excludes `.git`, so `python -m searx.version freeze` cannot run
during the build; `version_frozen.py` is generated from build args instead.
Without it, `searx/version.py` shells out to git on every import and logs errors.

### `docker-compose.yml` service block

Replaces the stock `image: docker.io/searxng/searxng:latest`. Assumes this fork
is checked out in a sibling directory next to the compose file.

```yaml
  searxng:
    container_name: searxng
    build:
      context: ./searxng-src
      dockerfile: Dockerfile
      args:
        VERSION: "2026.7.29-curlcffi"
        VCS_URL: "https://github.com/alex30303030/searxng"
    image: searxng-curlcffi:latest
    restart: unless-stopped
    ports:
      - "8080:8080"
    volumes:
      - ./config/:/etc/searxng/:rw
      - searxng-data:/var/cache/searxng/
    environment:
      - SEARXNG_BASE_URL=http://localhost:8080/
```

Keep whatever `ports`, `networks`, `env_file` and volume paths the existing
service already uses — only `image:` needs to become `build:` + a local `image:`
tag. Then:

```bash
docker compose build searxng && docker compose up -d searxng
```

Enabling the patch is a `settings.yml` change, not an image change: add
`impersonate: chrome` under `outgoing:` in the bind-mounted config and restart.
The image is inert until then.
