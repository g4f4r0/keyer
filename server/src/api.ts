export function json(value: unknown, status = 200): Response {
  return Response.json(value, { status, headers: { "cache-control": "no-store" } })
}

export async function authenticated(request: Request, operation: () => Promise<Response> | Response) {
  const expected = process.env.UPLOAD_TOKEN || ""
  if (!expected || request.headers.get("authorization") !== `Bearer ${expected}`) {
    return json({ error: "Unauthorized" }, 401)
  }
  return operation()
}
