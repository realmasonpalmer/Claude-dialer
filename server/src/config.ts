function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`Missing required env var ${name}`);
  return value;
}

export interface Config {
  port: number;
  publicBaseUrl: string;
  clarityApiKey: string;
  ticketSecret: string;
  twilio: {
    accountSid: string;
    authToken: string;
    apiKeySid: string;
    apiKeySecret: string;
    twimlAppSid: string;
    callerId: string;
  };
}

export function loadConfig(): Config {
  return {
    port: Number(process.env.PORT ?? 8080),
    publicBaseUrl: required("PUBLIC_BASE_URL").replace(/\/$/, ""),
    clarityApiKey: required("CLARITY_API_KEY"),
    ticketSecret: required("TICKET_SECRET"),
    twilio: {
      accountSid: required("TWILIO_ACCOUNT_SID"),
      authToken: required("TWILIO_AUTH_TOKEN"),
      apiKeySid: required("TWILIO_API_KEY_SID"),
      apiKeySecret: required("TWILIO_API_KEY_SECRET"),
      twimlAppSid: required("TWILIO_TWIML_APP_SID"),
      callerId: required("TWILIO_CALLER_ID"),
    },
  };
}
