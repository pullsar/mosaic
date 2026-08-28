FROM node:24.7.0-bookworm-slim AS build

WORKDIR /workspace/apps/api

COPY apps/api/package.json apps/api/package-lock.json ./
RUN npm ci --ignore-scripts

COPY apps/api/tsconfig.json apps/api/tsconfig.build.json ./
COPY apps/api/src ./src
COPY apps/api/test ./test
COPY apps/api/migrations ./migrations
COPY contracts /workspace/contracts
COPY packages/play_schema/fixtures /workspace/packages/play_schema/fixtures

RUN npm run typecheck \
    && npm test \
    && npm run build

FROM build AS ci

FROM build AS production

RUN npm prune --omit=dev --ignore-scripts

FROM node:24.7.0-bookworm-slim AS runtime

ENV NODE_ENV=production \
    HOST=0.0.0.0 \
    PORT=8080

WORKDIR /app

COPY --from=production --chown=node:node /workspace/apps/api/package.json ./package.json
COPY --from=production --chown=node:node /workspace/apps/api/node_modules ./node_modules
COPY --from=production --chown=node:node /workspace/apps/api/dist ./dist
COPY --from=production --chown=node:node /workspace/apps/api/migrations ./migrations

USER node
EXPOSE 8080

HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=3 \
  CMD ["node", "-e", "fetch('http://127.0.0.1:8080/ready').then((response) => process.exit(response.ok ? 0 : 1)).catch(() => process.exit(1))"]

CMD ["node", "--enable-source-maps", "dist/server.js"]
