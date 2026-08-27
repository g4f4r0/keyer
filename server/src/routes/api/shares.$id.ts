import { createFileRoute } from "@tanstack/react-router"
import { authenticated, json } from "@/api"
import { getShare } from "@/db"

export const Route = createFileRoute("/api/shares/$id")({
  server: { handlers: { GET: ({ request, params }) => authenticated(request, () => {
    const share = getShare(params.id)
    return share ? json(share) : json({ error: "Not found" }, 404)
  }) } },
})
