import { addBetaTester } from "./asc"

export interface Env {
  SIGNUPS: KVNamespace
  ASC_KEY_ID: string
  ASC_ISSUER_ID: string
  ASC_PRIVATE_KEY: string
  ASC_BETA_GROUP_ID: string
  ALLOWED_ORIGINS: string
  RATE_LIMIT_MAX: string
  RATE_LIMIT_WINDOW_SECONDS: string
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/

export default {
  async fetch(request: Request, env: Env, _ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url)

    if (request.method === "OPTIONS") {
      return preflight(request, env)
    }

    if (request.method === "POST" && url.pathname === "/signup") {
      return handleSignup(request, env)
    }

    return jsonResponse({ error: "not found" }, 404, corsHeaders(request, env))
  },
}

async function handleSignup(request: Request, env: Env): Promise<Response> {
  const cors = corsHeaders(request, env)

  let body: { email?: unknown }
  try {
    body = (await request.json()) as { email?: unknown }
  } catch {
    return jsonResponse({ error: "invalid JSON body" }, 400, cors)
  }

  const rawEmail = typeof body.email === "string" ? body.email : ""
  const email = rawEmail.trim().toLowerCase()
  if (!email || email.length > 254 || !EMAIL_RE.test(email)) {
    return jsonResponse({ error: "invalid email" }, 400, cors)
  }

  // Rate limit per IP — KV-backed, eventually consistent but fine for spam.
  const ip =
    request.headers.get("CF-Connecting-IP") ??
    request.headers.get("X-Forwarded-For")?.split(",")[0]?.trim() ??
    "unknown"
  const rl = await checkRateLimit(env, ip)
  if (!rl.ok) {
    return jsonResponse(
      { error: "too many requests" },
      429,
      { ...cors, "Retry-After": String(rl.retryAfter) },
    )
  }

  // Idempotent short-circuit: if we already processed this email successfully
  // recently, don't re-call ASC.
  const existing = await env.SIGNUPS.get(emailKey(email), "json")
  if (existing && typeof existing === "object") {
    const e = existing as { status?: string }
    if (e.status === "added" || e.status === "already_in_asc") {
      return jsonResponse(
        { ok: true, alreadyExisted: true },
        200,
        cors,
      )
    }
  }

  const result = await addBetaTester(
    {
      keyId: env.ASC_KEY_ID,
      issuerId: env.ASC_ISSUER_ID,
      privateKeyPem: env.ASC_PRIVATE_KEY,
    },
    email,
    env.ASC_BETA_GROUP_ID,
  )

  const record = {
    email,
    ip,
    createdAt: new Date().toISOString(),
    status: result.ok
      ? result.alreadyExisted
        ? "already_in_asc"
        : "added"
      : "asc_error",
    testerId: result.ok ? result.testerId : null,
    error: result.ok ? null : result.error,
  }

  // Best-effort write — failure shouldn't block the user response.
  try {
    await env.SIGNUPS.put(emailKey(email), JSON.stringify(record))
  } catch (err) {
    console.error("KV put failed", err)
  }

  if (!result.ok) {
    console.error("ASC signup failed", { email, error: result.error })
    // Surface generic message to the client; full detail is in record.
    return jsonResponse(
      { error: "could not add tester, please try again later" },
      502,
      cors,
    )
  }

  return jsonResponse(
    { ok: true, alreadyExisted: result.alreadyExisted },
    result.alreadyExisted ? 200 : 201,
    cors,
  )
}

async function checkRateLimit(
  env: Env,
  ip: string,
): Promise<{ ok: true } | { ok: false; retryAfter: number }> {
  const max = Number(env.RATE_LIMIT_MAX) || 5
  const window = Number(env.RATE_LIMIT_WINDOW_SECONDS) || 600
  const key = `rl:ip:${ip}`
  const raw = await env.SIGNUPS.get(key)
  const count = raw ? Number(raw) : 0
  if (count >= max) {
    return { ok: false, retryAfter: window }
  }
  await env.SIGNUPS.put(key, String(count + 1), { expirationTtl: window })
  return { ok: true }
}

function emailKey(email: string): string {
  return `email:${email}`
}

function corsHeaders(request: Request, env: Env): Record<string, string> {
  const origin = request.headers.get("Origin") ?? ""
  const allowed = (env.ALLOWED_ORIGINS || "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean)
  const matched = allowed.includes(origin) ? origin : allowed[0] ?? "*"
  return {
    "Access-Control-Allow-Origin": matched,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
    "Access-Control-Max-Age": "86400",
    Vary: "Origin",
  }
}

function preflight(request: Request, env: Env): Response {
  return new Response(null, { status: 204, headers: corsHeaders(request, env) })
}

function jsonResponse(
  body: unknown,
  status: number,
  extraHeaders: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      ...extraHeaders,
    },
  })
}
