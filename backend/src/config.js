import { readFileSync } from 'node:fs';

const DEFAULT_TEAM_ID = 'TEAMID1234'; // placeholder — set APNS_TEAM_ID to your Apple Developer team ID
const DEFAULT_TOPIC = 'com.openappsstudio.contactssync';

function toInt(value, fallback) {
  const n = Number.parseInt(value, 10);
  return Number.isFinite(n) ? n : fallback;
}

/**
 * Build the runtime configuration from environment variables.
 * Missing APNs config is not fatal: `config.apns` is simply null and the
 * dispatcher no-ops, so the server always starts.
 */
export function loadConfig(env = process.env) {
  const port = toInt(env.PORT, 8080);
  const pushIntervalMin = Math.min(Math.max(toInt(env.PUSH_INTERVAL_MIN, 20), 1), 24 * 60);

  // APNs auth key: inline PEM (APNS_KEY_P8, "\n" escapes allowed) or a file path.
  let apnsKey = null;
  if (env.APNS_KEY_P8) {
    apnsKey = env.APNS_KEY_P8.includes('\\n') ? env.APNS_KEY_P8.replace(/\\n/g, '\n') : env.APNS_KEY_P8;
  } else if (env.APNS_KEY_PATH) {
    apnsKey = readFileSync(env.APNS_KEY_PATH, 'utf8');
  }

  const apnsEnv = env.APNS_ENV === 'sandbox' ? 'sandbox' : 'production';
  const apns = apnsKey && env.APNS_KEY_ID
    ? {
        key: apnsKey,
        keyId: env.APNS_KEY_ID,
        teamId: env.APNS_TEAM_ID || DEFAULT_TEAM_ID,
        topic: env.APNS_TOPIC || DEFAULT_TOPIC,
        host: apnsEnv === 'sandbox' ? 'api.sandbox.push.apple.com' : 'api.push.apple.com',
        env: apnsEnv,
      }
    : null;

  const store = env.STORE === 'azure' ? 'azure' : 'memory';
  const azure = {
    account: env.AZURE_TABLES_ACCOUNT || null,
    key: env.AZURE_TABLES_KEY || null,
    sas: env.AZURE_TABLES_SAS || null,
    table: env.AZURE_TABLES_TABLE || 'devices',
  };
  if (store === 'azure' && (!azure.account || (!azure.key && !azure.sas))) {
    throw new Error('STORE=azure requires AZURE_TABLES_ACCOUNT and AZURE_TABLES_KEY (or AZURE_TABLES_SAS)');
  }

  return {
    port,
    pushIntervalMin,
    apns,
    store,
    azure,
    memoryStoreFile: env.MEMORY_STORE_FILE || null,
  };
}
