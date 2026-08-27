export function Brand({ suffix }: { suffix?: string }) {
  return (
    <div className="brand">
      <span className="mark" aria-hidden="true">K</span>
      <span>Keyer{suffix ? ` · ${suffix}` : ""}</span>
    </div>
  )
}
