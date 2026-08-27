import { createFileRoute } from "@tanstack/react-router"
import { Brand } from "@/components/brand"

export const Route = createFileRoute("/")({ component: HomePage })

function HomePage() {
  return <main className="page"><section className="card empty"><Brand /><h1>Speak. Share.</h1><p className="meta">Private-by-default transcript sharing.</p></section></main>
}
