import { createFileRoute, notFound } from "@tanstack/react-router"
import { createServerFn } from "@tanstack/react-start"
import { getShare } from "@/db"
import { Brand } from "@/components/brand"

const loadShare = createServerFn({ method: "GET" }).validator((id: string) => id).handler(({ data }) => getShare(data))

export const Route = createFileRoute("/$id")({
  loader: async ({ params }) => {
    if (!/^[a-f0-9]{10}$/.test(params.id)) throw notFound()
    const share = await loadShare({ data: params.id })
    if (!share) throw notFound()
    return share
  },
  head: ({ loaderData }) => loaderData ? { meta: [{ title: `${loaderData.title} — Keyer` }, { name: "description", content: `A ${loaderData.kind} shared with Keyer` }] } : {},
  component: SharePage,
  notFoundComponent: () => <main className="page"><section className="card empty"><Brand /><h1>Share not found</h1><p className="meta">This link is invalid or has expired.</p></section></main>,
})

function SharePage() {
  const share = Route.useLoaderData()
  return <main className="page"><article className="card"><Brand suffix={share.kind} /><h1>{share.title}</h1><div className="meta">{new Date(`${share.createdAt}Z`).toLocaleString()}</div><div className="content">{share.content}</div></article></main>
}
