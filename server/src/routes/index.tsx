import { createFileRoute } from "@tanstack/react-router"

export const Route = createFileRoute("/")({ component: HomePage })

function HomePage() {
  return (
    <main className="home" aria-label="Keyer">
      <span className="home-mark" aria-hidden="true">K</span>
    </main>
  )
}
