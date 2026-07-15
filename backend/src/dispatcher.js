const PRUNE_REASONS = new Set(['Unregistered', 'BadDeviceToken']);

/**
 * Run `worker` over `items` with at most `limit` in flight at once.
 * `worker` must not throw (callers wrap their own error handling).
 */
async function runPool(items, limit, worker) {
  let next = 0;
  const lanes = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (next < items.length) {
      const item = items[next++];
      await worker(item);
    }
  });
  await Promise.all(lanes);
}

/**
 * Periodic APNs dispatcher.
 *
 * Every `intervalMs` it scans the store and sends a silent background push to
 * each device whose per-device cadence has elapsed since its lastPushAt.
 *
 * Response handling:
 *   200                          -> recordPush(now)
 *   410 / Unregistered /
 *   BadDeviceToken               -> remove device
 *   anything else (429, 5xx,
 *   transport errors)            -> leave untouched; retried next cycle
 *
 * `apns` is injectable (anything with `send(token) -> {status, reason}`);
 * pass null when APNs is not configured and the dispatcher no-ops.
 */
export function createDispatcher({
  store,
  apns = null,
  intervalMs = 20 * 60 * 1000,
  concurrency = 10,
  now = Date.now,
  log = console,
}) {
  let timer = null;
  let lastDispatchAt = null;
  let running = false;
  let warnedUnconfigured = false;

  async function runOnce() {
    if (!apns) {
      if (!warnedUnconfigured) {
        log.warn('[dispatcher] APNs not configured — pushes disabled (set APNS_KEY_P8/APNS_KEY_PATH and APNS_KEY_ID)');
        warnedUnconfigured = true;
      }
      return { due: 0, sent: 0, pruned: 0, deferred: 0 };
    }
    if (running) return { due: 0, sent: 0, pruned: 0, deferred: 0, skipped: true };
    running = true;
    try {
      const startedAt = now();
      const devices = await store.all();
      const due = devices.filter(
        (d) => d.lastPushAt == null || startedAt - d.lastPushAt >= d.cadenceMinutes * 60_000,
      );

      let sent = 0;
      let pruned = 0;
      let deferred = 0;

      await runPool(due, concurrency, async (device) => {
        try {
          const { status, reason } = await apns.send(device.token);
          if (status === 200) {
            await store.recordPush(device.token, now());
            sent += 1;
          } else if (status === 410 || PRUNE_REASONS.has(reason)) {
            await store.remove(device.token);
            pruned += 1;
            log.log(`[dispatcher] pruned device (status=${status} reason=${reason ?? 'n/a'})`);
          } else {
            // 429, 5xx, or anything unexpected: try again next cycle.
            deferred += 1;
            log.warn(`[dispatcher] push deferred (status=${status} reason=${reason ?? 'n/a'}); will retry next cycle`);
          }
        } catch (err) {
          deferred += 1;
          log.warn(`[dispatcher] push failed (${err.message}); will retry next cycle`);
        }
      });

      lastDispatchAt = new Date(startedAt).toISOString();
      if (due.length > 0) {
        log.log(`[dispatcher] cycle done: due=${due.length} sent=${sent} pruned=${pruned} deferred=${deferred}`);
      }
      return { due: due.length, sent, pruned, deferred };
    } finally {
      running = false;
    }
  }

  return {
    runOnce,

    start() {
      if (timer) return;
      timer = setInterval(() => {
        runOnce().catch((err) => log.error(`[dispatcher] cycle error: ${err.message}`));
      }, intervalMs);
      timer.unref?.();
      // Kick off an immediate cycle so restarts don't delay pushes; per-device
      // cadence still prevents over-pushing.
      runOnce().catch((err) => log.error(`[dispatcher] cycle error: ${err.message}`));
    },

    stop() {
      if (timer) clearInterval(timer);
      timer = null;
    },

    get lastDispatchAt() {
      return lastDispatchAt;
    },
  };
}

/** Convenience wrapper: create a dispatcher and start it immediately. */
export function startDispatcher(options) {
  const dispatcher = createDispatcher(options);
  dispatcher.start();
  return dispatcher;
}
