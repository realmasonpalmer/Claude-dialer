import { createHmac, randomBytes, timingSafeEqual } from "node:crypto";

// A call ticket proves Salesforce approved this exact number for this user
// (Do Not Call and calling hours already checked). The browser cannot dial
// anything else, and each ticket works once.

export interface TicketClaims {
  identity: string;
  to: string;
  recordId: string;
  exp: number; // unix seconds
  nonce: string;
}

const TICKET_TTL_SECONDS = 120;

function sign(payload: string, secret: string): string {
  return createHmac("sha256", secret).update(payload).digest("base64url");
}

export function issueTicket(
  claims: Omit<TicketClaims, "exp" | "nonce">,
  secret: string,
  now = Date.now(),
): string {
  const full: TicketClaims = {
    ...claims,
    exp: Math.floor(now / 1000) + TICKET_TTL_SECONDS,
    nonce: randomBytes(12).toString("base64url"),
  };
  const payload = Buffer.from(JSON.stringify(full)).toString("base64url");
  return `${payload}.${sign(payload, secret)}`;
}

export class TicketStore {
  private used = new Map<string, number>();

  constructor(private secret: string) {}

  /** Returns the claims if the ticket is valid for this identity and number, then burns it. */
  redeem(ticket: string, identity: string, to: string, now = Date.now()): TicketClaims | null {
    const [payload, signature] = ticket.split(".");
    if (!payload || !signature) return null;

    const expected = Buffer.from(sign(payload, this.secret));
    const given = Buffer.from(signature);
    if (expected.length !== given.length || !timingSafeEqual(expected, given)) return null;

    let claims: TicketClaims;
    try {
      claims = JSON.parse(Buffer.from(payload, "base64url").toString("utf8"));
    } catch {
      return null;
    }

    const nowSeconds = Math.floor(now / 1000);
    if (claims.exp < nowSeconds) return null;
    if (claims.identity !== identity || claims.to !== to) return null;
    if (this.used.has(claims.nonce)) return null;

    this.used.set(claims.nonce, claims.exp);
    this.sweep(nowSeconds);
    return claims;
  }

  private sweep(nowSeconds: number) {
    for (const [nonce, exp] of this.used) {
      if (exp < nowSeconds) this.used.delete(nonce);
    }
  }
}

/** v1 dials US and Canada only. Returns E.164 or null. */
export function normalizeNanp(raw: string): string | null {
  const digits = raw.replace(/\D/g, "");
  if (digits.length === 10) return `+1${digits}`;
  if (digits.length === 11 && digits.startsWith("1")) return `+${digits}`;
  return null;
}
