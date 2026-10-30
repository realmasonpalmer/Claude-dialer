import { createApp } from "./app.js";
import { loadConfig } from "./config.js";

const config = loadConfig();
createApp(config).listen(config.port, () => {
  console.log(`clarity-dialer-server listening on :${config.port}`);
});
