import { loadConfig } from './config.js';
import { createApp } from './app.js';
import { MemoryDeviceStore } from './store/memory.js';
import { AzureTableDeviceStore } from './store/azureTable.js';
import { ApnsClient } from './apns.js';
import { createDispatcher } from './dispatcher.js';

const config = loadConfig();

const store =
  config.store === 'azure'
    ? new AzureTableDeviceStore(config.azure)
    : new MemoryDeviceStore({ filePath: config.memoryStoreFile });
if (store.init) await store.init();

const apns = config.apns
  ? new ApnsClient({
      key: config.apns.key,
      keyId: config.apns.keyId,
      teamId: config.apns.teamId,
      topic: config.apns.topic,
      host: config.apns.host,
    })
  : null;

const dispatcher = createDispatcher({
  store,
  apns,
  intervalMs: config.pushIntervalMin * 60_000,
});

const app = createApp({
  store,
  stats: () => ({ lastDispatchAt: dispatcher.lastDispatchAt }),
});

const server = app.listen(config.port, () => {
  console.log(
    `free-contacts-sync-backend listening on :${config.port} ` +
      `(store=${config.store}, apns=${config.apns ? config.apns.env : 'not configured'}, ` +
      `interval=${config.pushIntervalMin}min)`,
  );
});

dispatcher.start();

function shutdown(signal) {
  console.log(`received ${signal}, shutting down`);
  dispatcher.stop();
  apns?.close();
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 5_000).unref();
}
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
