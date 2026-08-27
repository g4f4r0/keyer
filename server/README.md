# Keyer server

Small self-hosted TanStack Start service for public Keyer share links. It runs as one lightweight Bun container and stores transcript text in a persistent SQLite volume.

## Docker Compose

```sh
cp .env.example .env
# Set UPLOAD_TOKEN and PUBLIC_BASE_URL in .env
docker compose up -d --build
```

That is the whole deployment. The service listens on port `3427` by default, restarts automatically, and keeps its database in the `keyer-data` Docker volume. To use another host port, set `KEYER_PORT`.

Check it with:

```sh
docker compose ps
curl http://localhost:3427/api/health
```

## Local development

```sh
cp .env.example .env
bun install
bun run dev
```

Create a share:

```sh
curl -X POST http://localhost:3427/api/shares \
  -H 'Authorization: Bearer replace-with-a-long-random-secret' \
  -H 'Content-Type: application/json' \
  -d '{"kind":"dictation","title":"Quick note","content":"Hello from Keyer."}'
```

Set `PUBLIC_BASE_URL` to the externally visible origin so returned share URLs use the correct domain.
