import express from "express";
import { createServer } from "node:http";
import { fileURLToPath } from "node:url";
import { createApp } from "./app.js";
import { attachCoach, loadCoachConfig } from "./coach/index.js";
import { loadConfig } from "./config.js";

const PUBLIC_DIR = fileURLToPath(new URL("../public", import.meta.url));

// The dialer (Twilio) and the coach (mic + Deepgram + Claude) are independent.
// Each turns on only when its env vars are set.
const dialerEnabled = Boolean(process.env.TWILIO_ACCOUNT_SID);
const app = dialerEnabled ? createApp(loadConfig()) : express();
if (!dialerEnabled) app.get("/health", (_req, res) => { res.json({ ok: true }); });

const coachConfig = loadCoachConfig();
app.use("/coach", express.static(PUBLIC_DIR));

const server = createServer(app);
if (coachConfig) attachCoach(server, coachConfig);

const port = Number(process.env.PORT ?? 8080);
server.listen(port, () => {
  console.log(
    `clarity-dialer-server on :${port} (dialer ${dialerEnabled ? "on" : "off"}, coach ${coachConfig ? `on, ${coachConfig.settings.model}` : "off"})`,
  );
});
