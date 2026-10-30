import express, { type NextFunction, type Request, type Response } from "express";
import { timingSafeEqual } from "node:crypto";
import twilio from "twilio";
import type { Config } from "./config.js";
import { issueTicket, normalizeNanp, TicketStore } from "./tickets.js";

const { AccessToken } = twilio.jwt;
const { VoiceGrant } = AccessToken;
const TOKEN_TTL_SECONDS = 3600;

// Salesforce user Ids are the Twilio client identity.
const SF_USER_ID = /^005[a-zA-Z0-9]{12}(?:[a-zA-Z0-9]{3})?$/;
const SF_RECORD_ID = /^[a-zA-Z0-9]{15}(?:[a-zA-Z0-9]{3})?$/;

export function identityFor(userId: string): string {
  return `sf_${userId}`;
}

export function createApp(config: Config) {
  const app = express();
  const tickets = new TicketStore(config.ticketSecret);

  app.disable("x-powered-by");
  app.use(express.json({ limit: "32kb" }));
  app.use(express.urlencoded({ extended: false, limit: "32kb" }));

  function mintToken(identity: string): string {
    const token = new AccessToken(
      config.twilio.accountSid,
      config.twilio.apiKeySid,
      config.twilio.apiKeySecret,
      { identity, ttl: TOKEN_TTL_SECONDS },
    );
    token.addGrant(
      new VoiceGrant({ outgoingApplicationSid: config.twilio.twimlAppSid, incomingAllow: false }),
    );
    return token.toJwt();
  }

  // Only Salesforce (via its Named Credential) may call /api routes.
  function requireApiKey(req: Request, res: Response, next: NextFunction) {
    const given = Buffer.from(req.get("x-clarity-key") ?? "");
    const expected = Buffer.from(config.clarityApiKey);
    if (given.length !== expected.length || !timingSafeEqual(given, expected)) {
      res.status(401).json({ error: "unauthorized" });
      return;
    }
    next();
  }

  // Twilio signs every webhook. Reject anything it did not send.
  function requireTwilioSignature(req: Request, res: Response, next: NextFunction) {
    const url = config.publicBaseUrl + req.originalUrl;
    const ok = twilio.validateRequest(
      config.twilio.authToken,
      req.get("x-twilio-signature") ?? "",
      url,
      req.body ?? {},
    );
    if (!ok) {
      res.status(403).send("invalid signature");
      return;
    }
    next();
  }

  app.get("/health", (_req, res) => {
    res.json({ ok: true });
  });

  app.post("/api/token", requireApiKey, (req, res) => {
    const userId = String(req.body?.userId ?? "");
    if (!SF_USER_ID.test(userId)) {
      res.status(400).json({ error: "bad userId" });
      return;
    }
    res.json({ token: mintToken(identityFor(userId)), ttl: TOKEN_TTL_SECONDS });
  });

  // Salesforce calls this after its own checks pass. Returns a one-time ticket
  // the browser must hand back to Twilio when it dials.
  app.post("/api/calls/authorize", requireApiKey, (req, res) => {
    const userId = String(req.body?.userId ?? "");
    const recordId = String(req.body?.recordId ?? "");
    const to = normalizeNanp(String(req.body?.to ?? ""));
    if (!SF_USER_ID.test(userId) || !SF_RECORD_ID.test(recordId)) {
      res.status(400).json({ error: "bad ids" });
      return;
    }
    if (!to) {
      res.status(400).json({ error: "only US and Canada numbers are supported" });
      return;
    }
    const identity = identityFor(userId);
    res.json({
      to,
      ticket: issueTicket({ identity, to, recordId }, config.ticketSecret),
      token: mintToken(identity),
    });
  });

  // TwiML App Voice URL. Runs when the browser calls device.connect().
  app.post("/twilio/voice", requireTwilioSignature, (req, res) => {
    const response = new twilio.twiml.VoiceResponse();
    const from = String(req.body.From ?? "");
    const identity = from.startsWith("client:") ? from.slice("client:".length) : "";
    const to = normalizeNanp(String(req.body.To ?? ""));
    const claims = to ? tickets.redeem(String(req.body.ticket ?? ""), identity, to) : null;

    if (!to || !claims) {
      console.warn(JSON.stringify({ event: "dial_rejected", identity, callSid: req.body.CallSid }));
      response.say("This call was not approved. Please dial again from Salesforce.");
      response.hangup();
    } else {
      console.log(
        JSON.stringify({ event: "dial", identity, recordId: claims.recordId, callSid: req.body.CallSid }),
      );
      const dial = response.dial({
        callerId: config.twilio.callerId,
        answerOnBridge: true, // browser only sees "accept" when the prospect answers
        timeout: 30,
      });
      dial.number(
        {
          statusCallback: `${config.publicBaseUrl}/twilio/dial-status`,
          statusCallbackEvent: ["initiated", "ringing", "answered", "completed"],
        },
        to,
      );
    }
    res.type("text/xml").send(response.toString());
  });

  // Raw call events. Kept as logs for now; the dashboard phase reads these.
  app.post("/twilio/dial-status", requireTwilioSignature, (req, res) => {
    console.log(
      JSON.stringify({
        event: "dial_status",
        parentCallSid: req.body.ParentCallSid,
        callSid: req.body.CallSid,
        status: req.body.CallStatus,
        duration: req.body.CallDuration,
        timestamp: req.body.Timestamp,
      }),
    );
    res.sendStatus(204);
  });

  return app;
}
