import { createFileRoute } from "@tanstack/react-router"
import { authenticated, json } from "@/api"
import { saveRecord } from "@/db"

export const Route = createFileRoute("/api/records")({
  server: {
    handlers: {
      POST: ({ request }) => authenticated(request, async () => {
        let body: unknown
        try { body = await request.json() } catch { return json({ error: "Invalid JSON" }, 400) }
        if (!body || typeof body !== "object") return json({ error: "Invalid record" }, 400)
        const record = body as Record<string, unknown>
        if (typeof record.id !== "string" || typeof record.kind !== "string" || typeof record.createdAt !== "string") {
          return json({ error: "Invalid record" }, 400)
        }
        if (record.kind !== "dictation" && record.kind !== "meeting") return json({ error: "Invalid kind" }, 400)
        const payload = JSON.stringify(body)
        if (payload.length > 1_000_000) return json({ error: "Record is too large" }, 400)
        saveRecord({ id: record.id, kind: record.kind, createdAt: record.createdAt, payload })
        return json({ ok: true }, 201)
      }),
    },
  },
})
