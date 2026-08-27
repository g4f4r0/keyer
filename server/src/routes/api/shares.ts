import { createFileRoute } from "@tanstack/react-router"
import { authenticated, json } from "@/api"
import { createShare } from "@/db"

type ShareInput = { kind?: unknown; title?: unknown; content?: unknown; expiresAt?: unknown }

export const Route = createFileRoute("/api/shares")({
  server: {
    handlers: {
      POST: ({ request }) => authenticated(request, async () => {
        let body: ShareInput
        try { body = await request.json() as ShareInput } catch { return json({ error: "Invalid JSON" }, 400) }
        if (body.kind !== "dictation" && body.kind !== "meeting") return json({ error: "Invalid kind" }, 400)
        if (typeof body.content !== "string" || !body.content.trim() || body.content.length > 1_000_000) return json({ error: "Content is required and must be under 1 MB" }, 400)
        const title = typeof body.title === "string" ? body.title.trim().slice(0, 200) : ""
        const expiresAt = body.expiresAt == null ? null : typeof body.expiresAt === "string" ? body.expiresAt : undefined
        if (expiresAt === undefined || (expiresAt && Number.isNaN(Date.parse(expiresAt)))) return json({ error: "Invalid expiresAt" }, 400)
        const id = crypto.randomUUID().replaceAll("-", "").slice(0, 10)
        const share = createShare({ id, kind: body.kind, title: title || (body.kind === "meeting" ? "Meeting" : "Dictation"), content: body.content.trim(), expiresAt })
        const origin = process.env.PUBLIC_BASE_URL?.replace(/\/$/, "") || new URL(request.url).origin
        return json({ ...share, url: `${origin}/${id}` }, 201)
      }),
    },
  },
})
