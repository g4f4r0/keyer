FROM oven/bun:1.4.0-alpine AS build
WORKDIR /app
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile
COPY . .
RUN bun run typecheck && bun run build

FROM oven/bun:1.4.0-alpine AS runtime
WORKDIR /app
ENV NODE_ENV=production PORT=3427 DATABASE_PATH=/app/data/keyer.sqlite
COPY --from=build --chown=bun:bun /app/.output ./.output
RUN mkdir -p /app/data && chown bun:bun /app/data
USER bun
EXPOSE 3427
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD bun -e 'const r=await fetch("http://127.0.0.1:3427/api/health");if(!r.ok)process.exit(1)'
CMD ["bun", "run", ".output/server/index.mjs"]
