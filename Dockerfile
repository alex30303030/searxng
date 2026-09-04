# syntax=docker/dockerfile:1

# Self-contained image build for this patched SearXNG fork.
#
# Upstream splits the build across container/builder.dockerfile and
# container/dist.dockerfile, where dist.dockerfile starts FROM
# `localhost/searxng/searxng:builder` -- an image you have to build and tag
# yourself first. That indirection serves upstream's release tooling, but it
# makes a plain `docker compose build` fail. Both stages are merged here so the
# image builds in a single step from a checkout of this branch.
#
# Otherwise kept deliberately close to upstream's two files, so that re-syncing
# after `git rebase upstream/master` is a readable diff. See NOTES.md.

FROM docker.io/searxng/base:searxng-builder AS builder

COPY ./requirements.txt ./requirements-server.txt ./

ENV UV_NO_MANAGED_PYTHON="true"
ENV UV_NATIVE_TLS="true"

ARG TIMESTAMP_VENV="0"

# Unchanged from upstream builder.dockerfile. The `strip --strip-unneeded` pass
# also hits curl_cffi's bundled libcurl-impersonate (_wrapper.abi3.so, ~38MB ->
# ~7MB); this was verified not to affect it -- the impersonated JA4 is identical
# before and after stripping.
RUN --mount=type=cache,id=uv,target=/root/.cache/uv set -eux -o pipefail; \
    export SOURCE_DATE_EPOCH="$TIMESTAMP_VENV"; \
    uv venv; \
    uv pip install --requirements ./requirements.txt --requirements ./requirements-server.txt; \
    uv cache prune --ci; \
    find ./.venv/lib/ -type f -exec strip --strip-unneeded {} + || true; \
    find ./.venv/lib/ -type d -name "__pycache__" -exec rm -rf {} +; \
    find ./.venv/lib/ -type f -name "*.pyc" -delete; \
    python -m compileall -q -f -j 0 --invalidation-mode=unchecked-hash ./.venv/lib/; \
    find ./.venv/lib/python*/site-packages/*.dist-info/ -type f -name "RECORD" -exec sort -t, -k1,1 -o {} {} \;; \
    find ./.venv/ -exec touch -h --date="@$TIMESTAMP_VENV" {} +

COPY --exclude=./searx/version_frozen.py ./searx/ ./searx/

ARG VERSION="unknown"
ARG VCS_URL="unknown"
ARG VCS_REVISION="unknown"
ARG GIT_BRANCH="feat/curl-cffi-transport"

# .dockerignore excludes .git, so `python -m searx.version freeze` cannot run in
# this stage. Generate version_frozen.py from build args instead: without it
# searx/version.py shells out to git on every import and logs errors.
RUN set -eux -o pipefail; \
    printf '%s\n' \
    '# SPDX-License-Identifier: AGPL-3.0-or-later' \
    '# pylint: disable=missing-module-docstring' \
    '# this file is generated automatically by the container build' \
    "VERSION_STRING = \"$VERSION\"" \
    "VERSION_TAG = \"$VERSION\"" \
    "DOCKER_TAG = \"$VERSION\"" \
    "GIT_URL = \"$VCS_URL\"" \
    "GIT_BRANCH = \"$GIT_BRANCH\"" \
    > ./searx/version_frozen.py

RUN set -eux -o pipefail; \
    python -m compileall -q -f -j 0 --invalidation-mode=unchecked-hash ./searx/; \
    find ./searx/static/ -type f \
    \( -name "*.html" -o -name "*.css" -o -name "*.js" -o -name "*.svg" \) \
    -exec gzip -9 -k {} + \
    -exec brotli -9 -k {} + \
    -exec gzip --test {}.gz + \
    -exec brotli --test {}.br +


FROM docker.io/searxng/base:searxng AS dist

# version_frozen.py is generated in the builder stage and arrives with ./searx/,
# so upstream's separate COPY of it is not needed here.
COPY --chown=977:977 --from=builder /usr/local/searxng/.venv/ ./.venv/
COPY --chown=977:977 --from=builder /usr/local/searxng/searx/ ./searx/
COPY --chown=977:977 ./container/ ./

ARG CREATED="0001-01-01T00:00:00Z"
ARG VERSION="unknown"
ARG VCS_URL="unknown"
ARG VCS_REVISION="unknown"

LABEL org.opencontainers.image.created="$CREATED" \
    org.opencontainers.image.description="SearXNG with browser TLS fingerprint impersonation (curl_cffi)." \
    org.opencontainers.image.documentation="https://docs.searxng.org/admin/installation-docker" \
    org.opencontainers.image.licenses="AGPL-3.0-or-later" \
    org.opencontainers.image.revision="$VCS_REVISION" \
    org.opencontainers.image.source="$VCS_URL" \
    org.opencontainers.image.title="SearXNG (curl_cffi fork)" \
    org.opencontainers.image.url="https://searxng.org" \
    org.opencontainers.image.version="$VERSION"

ENV __SEARXNG_VERSION="$VERSION" \
    __SEARXNG_SETTINGS_PATH="$__SEARXNG_CONFIG_PATH/settings.yml" \
    GRANIAN_PROCESS_NAME="searxng" \
    GRANIAN_INTERFACE="wsgi" \
    GRANIAN_HOST="::" \
    GRANIAN_PORT="8080" \
    GRANIAN_WEBSOCKETS="false" \
    GRANIAN_BLOCKING_THREADS="4" \
    GRANIAN_WORKERS_KILL_TIMEOUT="30s" \
    GRANIAN_BLOCKING_THREADS_IDLE_TIMEOUT="5m"

# "*_PATH" ENVs are defined in base images
VOLUME $__SEARXNG_CONFIG_PATH
VOLUME $__SEARXNG_DATA_PATH

EXPOSE 8080

ENTRYPOINT ["/usr/local/searxng/entrypoint.sh"]
