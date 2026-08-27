import { mkdir } from "node:fs/promises"
import { resolve } from "node:path"
import { createFileRoute } from "@tanstack/react-router"
import { authenticated, json } from "@/api"
import { attachRecordAudio } from "@/db"

export const Route = createFileRoute("/api/records/$id/audio")({
  server: {
    handlers: {
      PUT: ({ request, params }) => authenticated(request, async () => {
        if (!/^[0-9a-f-]{36}$/i.test(params.id)) return json({ error: "Invalid id" }, 400)
        const length = Number(request.headers.get("content-length") || 0)
        if (!length || length > 500_000_000) return json({ error: "Invalid audio size" }, 400)
        const directory = resolve(process.env.AUDIO_PATH || "./data/audio")
        await mkdir(directory, { recursive: true })
        const path = resolve(directory, `${params.id.toLowerCase()}.m4a`)
        await Bun.write(path, await request.arrayBuffer())
        if (!attachRecordAudio(params.id, path)) return json({ error: "Record not found" }, 404)
        return json({ ok: true })
      }),
    },
  },
})
