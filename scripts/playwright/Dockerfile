FROM harbor.local/data-platform/platform-node:22.22.0-bookworm-slim

ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
    NODE_ENV=production \
    PLAYWRIGHT_EXECUTABLE_PATH=/usr/bin/chromium \
    NODE_PATH=/opt/playwright-runner/node_modules

WORKDIR /opt/playwright-runner

RUN apt-get update \
    && apt-get install -y --no-install-recommends chromium \
    && rm -rf /var/lib/apt/lists/*

COPY scripts/playwright/package.json package.json
RUN npm install --omit=dev --no-audit --no-fund

WORKDIR /workspace
