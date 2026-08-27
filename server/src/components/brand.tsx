import { RiChatVoiceLine } from "react-icons/ri"

export function Brand({ suffix }: { suffix?: string }) {
  return (
    <div className="brand">
      <RiChatVoiceLine aria-hidden="true" />
      <span>Keyer{suffix ? ` · ${suffix}` : ""}</span>
    </div>
  )
}
