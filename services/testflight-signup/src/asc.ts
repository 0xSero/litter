// App Store Connect API client.
//
// Signs an ES256 JWT (Apple requires ES256 / P-256) using the .p8 key supplied
// as a Worker secret, then posts to /v1/betaTesters with the Beta Testers group
// relationship. App Store Connect itself sends the TestFlight invite email
// once the tester is created.

const ASC_BASE = "https://api.appstoreconnect.apple.com"
const JWT_AUD = "appstoreconnect-v1"
// Apple max is 20 minutes. Keep this short — we only sign per-request anyway.
const JWT_LIFETIME_SECONDS = 1200

type AscEnv = {
  keyId: string
  issuerId: string
  privateKeyPem: string
}

let cachedKey: { pem: string; key: CryptoKey } | null = null

async function importPrivateKey(pem: string): Promise<CryptoKey> {
  if (cachedKey && cachedKey.pem === pem) return cachedKey.key
  const body = pem
    .replace(/-----BEGIN [^-]+-----/g, "")
    .replace(/-----END [^-]+-----/g, "")
    .replace(/\s+/g, "")
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0))
  const key = await crypto.subtle.importKey(
    "pkcs8",
    der.buffer as ArrayBuffer,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  )
  cachedKey = { pem, key }
  return key
}

function b64url(bytes: Uint8Array | ArrayBuffer): string {
  const u8 = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes)
  let s = ""
  for (let i = 0; i < u8.length; i++) s += String.fromCharCode(u8[i])
  return btoa(s).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_")
}

function b64urlJSON(obj: unknown): string {
  return b64url(new TextEncoder().encode(JSON.stringify(obj)))
}

async function mintJWT(env: AscEnv): Promise<string> {
  const now = Math.floor(Date.now() / 1000)
  const header = { alg: "ES256", kid: env.keyId, typ: "JWT" }
  const payload = {
    iss: env.issuerId,
    iat: now,
    exp: now + JWT_LIFETIME_SECONDS,
    aud: JWT_AUD,
  }
  const signingInput = `${b64urlJSON(header)}.${b64urlJSON(payload)}`
  const key = await importPrivateKey(env.privateKeyPem)
  const sig = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput),
  )
  return `${signingInput}.${b64url(sig)}`
}

export type AscError = {
  status: number
  code?: string
  detail?: string
  raw?: unknown
}

export type AscResult =
  | { ok: true; testerId: string; alreadyExisted: false }
  | { ok: true; testerId: string | null; alreadyExisted: true }
  | { ok: false; error: AscError }

/**
 * Add an email to the Beta Testers group. Returns ok:true when the tester is
 * either newly created or was already present in App Store Connect (in either
 * case Apple's UI now reflects the group membership). Returns ok:false on
 * unexpected ASC errors so the caller can decide whether to retry.
 */
export async function addBetaTester(
  env: AscEnv,
  email: string,
  betaGroupId: string,
): Promise<AscResult> {
  const jwt = await mintJWT(env)
  const headers = {
    Authorization: `Bearer ${jwt}`,
    "Content-Type": "application/json",
    Accept: "application/json",
  }

  // Try to create directly with the betaGroups relationship — single round
  // trip on the happy path.
  const createBody = {
    data: {
      type: "betaTesters",
      attributes: { email },
      relationships: {
        betaGroups: {
          data: [{ type: "betaGroups", id: betaGroupId }],
        },
      },
    },
  }
  const createResp = await fetch(`${ASC_BASE}/v1/betaTesters`, {
    method: "POST",
    headers,
    body: JSON.stringify(createBody),
  })

  if (createResp.status === 201) {
    const json = (await createResp.json()) as { data?: { id?: string } }
    return { ok: true, testerId: json.data?.id ?? "", alreadyExisted: false }
  }

  const errJson = await createResp
    .json()
    .catch(() => ({}) as Record<string, unknown>)

  // Apple returns 409 (or sometimes 400) when the email already exists.
  // Try to find them and add to the group instead.
  if (createResp.status === 409 || createResp.status === 400) {
    const code = extractErrorCode(errJson)
    if (looksLikeAlreadyExists(code, errJson)) {
      const existing = await findTesterByEmail(jwt, email)
      if (existing) {
        const added = await addExistingTesterToGroup(jwt, existing, betaGroupId)
        if (added) return { ok: true, testerId: existing, alreadyExisted: true }
      }
      // Couldn't link them, but they exist in ASC — surface as already-existed.
      return { ok: true, testerId: null, alreadyExisted: true }
    }
  }

  return {
    ok: false,
    error: {
      status: createResp.status,
      code: extractErrorCode(errJson),
      detail: extractErrorDetail(errJson),
      raw: errJson,
    },
  }
}

async function findTesterByEmail(
  jwt: string,
  email: string,
): Promise<string | null> {
  const url = new URL(`${ASC_BASE}/v1/betaTesters`)
  url.searchParams.set("filter[email]", email)
  url.searchParams.set("limit", "1")
  const resp = await fetch(url.toString(), {
    headers: { Authorization: `Bearer ${jwt}`, Accept: "application/json" },
  })
  if (!resp.ok) return null
  const json = (await resp.json()) as { data?: Array<{ id?: string }> }
  return json.data?.[0]?.id ?? null
}

async function addExistingTesterToGroup(
  jwt: string,
  testerId: string,
  betaGroupId: string,
): Promise<boolean> {
  const resp = await fetch(
    `${ASC_BASE}/v1/betaGroups/${betaGroupId}/relationships/betaTesters`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${jwt}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        data: [{ type: "betaTesters", id: testerId }],
      }),
    },
  )
  // 204 = added; 409 = already a member, also fine.
  return resp.status === 204 || resp.status === 409
}

function extractErrorCode(json: unknown): string | undefined {
  const errs = (json as { errors?: Array<{ code?: string }> })?.errors
  return errs?.[0]?.code
}

function extractErrorDetail(json: unknown): string | undefined {
  const errs = (json as { errors?: Array<{ detail?: string; title?: string }> })
    ?.errors
  return errs?.[0]?.detail || errs?.[0]?.title
}

function looksLikeAlreadyExists(code: string | undefined, json: unknown): boolean {
  if (!code && !json) return false
  // ASC returns codes like ENTITY_ERROR.ATTRIBUTE.SPECIFIC.INVALID with detail
  // mentioning "is already being used". The safer signal is the detail string.
  const detail = extractErrorDetail(json) ?? ""
  return /already/i.test(detail) || code === "ENTITY_ERROR.RELATIONSHIP.INVALID"
}
