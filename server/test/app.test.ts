import assert from "node:assert/strict";
import type { AddressInfo } from "node:net";
import { after, before, test } from "node:test";
import twilio from "twilio";
import { createApp, identityFor } from "../src/app.js";
import type { Config } from "../src/config.js";

const config: Config = {
  port: 0,
  publicBaseUrl: "https://dialer.test",
  clarityApiKey: "k".repeat(32),
  ticketSecret: "ticket-secret",
  twilio: {
    accountSid: "AC" + "0".repeat(32),
    authToken: "auth-token",
    apiKeySid: "SK" + "0".repeat(32),
    apiKeySecret: "api-secret",
    twimlAppSid: "AP" + "0".repeat(32),
    callerId: "+15555550100",
  },
};

const USER = "005000000000001AAA";
const LEAD = "00Q000000000001AAA";
let base = "";
let close = () => {};

before(async () => {
  const server = createApp(config).listen(0);
  await new Promise((r) => server.once("listening", r));
  base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  close = () => server.close();
});
after(() => close());

function api(path: string, body: unknown, key = config.clarityApiKey) {
  return fetch(base + path, {
    method: "POST",
    headers: { "content-type": "application/json", "x-clarity-key": key },
    body: JSON.stringify(body),
  });
}

function twilioPost(path: string, params: Record<string, string>) {
  const signature = twilio.getExpectedTwilioSignature(
    config.twilio.authToken,
    config.publicBaseUrl + path,
    params,
  );
  return fetch(base + path, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded", "x-twilio-signature": signature },
    body: new URLSearchParams(params),
  });
}

test("api routes need the shared key", async () => {
  const res = await api("/api/token", { userId: USER }, "wrong");
  assert.equal(res.status, 401);
});

test("token route returns a Twilio JWT", async () => {
  const res = await api("/api/token", { userId: USER });
  assert.equal(res.status, 200);
  const { token } = (await res.json()) as { token: string };
  assert.equal(token.split(".").length, 3);
});

test("authorize then dial returns Dial TwiML once", async () => {
  const auth = await api("/api/calls/authorize", { userId: USER, recordId: LEAD, to: "(555) 555-0123" });
  assert.equal(auth.status, 200);
  const { ticket, to } = (await auth.json()) as { ticket: string; to: string };
  assert.equal(to, "+15555550123");

  const params = { From: `client:${identityFor(USER)}`, To: to, ticket, CallSid: "CA1" };
  const first = await (await twilioPost("/twilio/voice", params)).text();
  assert.match(first, /<Dial[^>]*answerOnBridge="true"[^>]*>.*<Number[^>]*>\+15555550123<\/Number>/s);

  const replay = await (await twilioPost("/twilio/voice", params)).text();
  assert.match(replay, /<Hangup/);
  assert.doesNotMatch(replay, /<Dial/);
});

test("authorize rejects non US/Canada numbers", async () => {
  const res = await api("/api/calls/authorize", { userId: USER, recordId: LEAD, to: "+44 20 7946 0958" });
  assert.equal(res.status, 400);
});

test("voice webhook rejects unsigned requests", async () => {
  const res = await fetch(base + "/twilio/voice", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ To: "+15555550123" }),
  });
  assert.equal(res.status, 403);
});
