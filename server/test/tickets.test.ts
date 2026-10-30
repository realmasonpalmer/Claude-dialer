import assert from "node:assert/strict";
import { test } from "node:test";
import { issueTicket, normalizeNanp, TicketStore } from "../src/tickets.js";

const SECRET = "test-secret";
const claims = { identity: "sf_005000000000001AAA", to: "+15555550123", recordId: "00Q000000000001AAA" };

test("valid ticket redeems once", () => {
  const store = new TicketStore(SECRET);
  const ticket = issueTicket(claims, SECRET);
  assert.equal(store.redeem(ticket, claims.identity, claims.to)?.recordId, claims.recordId);
  assert.equal(store.redeem(ticket, claims.identity, claims.to), null);
});

test("ticket is bound to identity and number", () => {
  const store = new TicketStore(SECRET);
  const ticket = issueTicket(claims, SECRET);
  assert.equal(store.redeem(ticket, "sf_someone_else", claims.to), null);
  assert.equal(store.redeem(ticket, claims.identity, "+15555550999"), null);
});

test("expired or tampered tickets fail", () => {
  const store = new TicketStore(SECRET);
  const old = issueTicket(claims, SECRET, Date.now() - 10 * 60 * 1000);
  assert.equal(store.redeem(old, claims.identity, claims.to), null);

  const forged = issueTicket(claims, "wrong-secret");
  assert.equal(store.redeem(forged, claims.identity, claims.to), null);
  assert.equal(store.redeem("garbage", claims.identity, claims.to), null);
});

test("normalizeNanp", () => {
  assert.equal(normalizeNanp("(555) 555-0123"), "+15555550123");
  assert.equal(normalizeNanp("1-555-555-0123"), "+15555550123");
  assert.equal(normalizeNanp("+44 20 7946 0958"), null);
  assert.equal(normalizeNanp("123"), null);
});
