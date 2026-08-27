import { createFileRoute } from "@tanstack/react-router"
import { json } from "@/api"

export const Route = createFileRoute("/api/health")({
  server: { handlers: { GET: () => json({ ok: true }) } },
})
