import { createFileRoute } from "@tanstack/react-router"
import { RiChatVoiceLine } from "react-icons/ri"

export const Route = createFileRoute("/")({ component: HomePage })

function HomePage() {
  return (
    <main className="home" aria-label="Keyer">
      <RiChatVoiceLine aria-hidden="true" />
    </main>
  )
}
