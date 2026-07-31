import express from 'express';

// APNs device tokens are 32+ bytes of hex (64+ chars); cap length to keep
// store keys and APNs paths sane.
const TOKEN_RE = /^[0-9a-f]{64,200}$/;

const DEFAULT_CADENCE_MINUTES = 20;
const MIN_CADENCE_MINUTES = 15;
const MAX_CADENCE_MINUTES = 240;

function securityHeaders(req, res, next) {
  res.set({
    'content-security-policy': "default-src 'none'; frame-ancestors 'none'",
    'strict-transport-security': 'max-age=63072000; includeSubDomains',
    'x-content-type-options': 'nosniff',
    'x-frame-options': 'DENY',
    'referrer-policy': 'no-referrer',
    'cross-origin-resource-policy': 'same-origin',
    'cross-origin-opener-policy': 'same-origin',
    'x-dns-prefetch-control': 'off',
    'x-permitted-cross-domain-policies': 'none',
    'cache-control': 'no-store',
  });
  next();
}

function requestLogger(req, res, next) {
  const startedAt = process.hrtime.bigint();
  res.on('finish', () => {
    const ms = Number(process.hrtime.bigint() - startedAt) / 1e6;
    // Never log device tokens: redact anything after the collection path.
    const path = req.originalUrl.startsWith('/v1/device/') ? '/v1/device/:token' : req.originalUrl;
    console.log(`${new Date().toISOString()} ${req.method} ${path} ${res.statusCode} ${ms.toFixed(1)}ms`);
  });
  next();
}

// Lightweight in-process fixed-window rate limiter for the write endpoints. The API is
// public and unauthenticated, so this is a basic abuse brake against registration
// floods — not a substitute for a real gateway/WAF, but zero-dependency and effective
// against a single-source script. Per-IP window.
const RATE_WINDOW_MS = 60_000;
const RATE_MAX = 60;
const rateHits = new Map(); // ip -> { count, resetAt }
function rateLimit(req, res, next) {
  const now = Date.now();
  const ip = req.ip || req.socket?.remoteAddress || 'unknown';
  let entry = rateHits.get(ip);
  if (!entry || now >= entry.resetAt) {
    entry = { count: 0, resetAt: now + RATE_WINDOW_MS };
    rateHits.set(ip, entry);
  }
  entry.count += 1;
  // Opportunistic cleanup so the map can't grow unbounded across many IPs.
  if (rateHits.size > 10_000) {
    for (const [k, v] of rateHits) if (now >= v.resetAt) rateHits.delete(k);
  }
  if (entry.count > RATE_MAX) {
    res.set('retry-after', String(Math.ceil((entry.resetAt - now) / 1000)));
    return res.status(429).json({ error: 'too many requests' });
  }
  return next();
}

/**
 * Express app factory.
 *
 * @param {object} deps
 * @param {import('./store/memory.js').MemoryDeviceStore} deps.store - any DeviceStore
 * @param {() => {lastDispatchAt: string|null}} [deps.stats] - dispatcher stats for /healthz
 */
export function createApp({ store, stats = () => ({ lastDispatchAt: null }) }) {
  const app = express();
  app.disable('x-powered-by');
  app.use(securityHeaders);
  app.use(requestLogger);
  app.use(express.json({ limit: '4kb' }));

  // Register (or refresh) a device token.
  app.post('/v1/device', rateLimit, async (req, res, next) => {
    try {
      const body = req.body ?? {};
      const token = typeof body.token === 'string' ? body.token.toLowerCase() : null;
      if (!token || !TOKEN_RE.test(token)) {
        return res.status(400).json({ error: 'token must be a hex string of 64+ characters' });
      }

      let cadenceMinutes = DEFAULT_CADENCE_MINUTES;
      if (body.cadenceMinutes !== undefined) {
        const c = body.cadenceMinutes;
        if (typeof c !== 'number' || !Number.isInteger(c) || c < MIN_CADENCE_MINUTES || c > MAX_CADENCE_MINUTES) {
          return res.status(400).json({
            error: `cadenceMinutes must be an integer between ${MIN_CADENCE_MINUTES} and ${MAX_CADENCE_MINUTES}`,
          });
        }
        cadenceMinutes = c;
      }

      await store.upsert({ token, cadenceMinutes });
      res.status(204).end();
    } catch (err) {
      next(err);
    }
  });

  // Unregister a device (idempotent).
  app.delete('/v1/device/:token', rateLimit, async (req, res, next) => {
    try {
      // Validate the token the same way as POST before it reaches the store:
      // an unvalidated path param would otherwise be interpolated into the
      // Azure Table entity/RowKey path (OData injection). Malformed → no-op.
      const token = typeof req.params.token === 'string' ? req.params.token.toLowerCase() : '';
      if (!TOKEN_RE.test(token)) {
        return res.status(400).json({ error: 'token must be a hex string of 64+ characters' });
      }
      await store.remove(token);
      res.status(204).end();
    } catch (err) {
      next(err);
    }
  });

  app.get('/healthz', (req, res) => {
    // Liveness only. We deliberately do NOT report a device count here: on the Azure
    // Table store counting is a full-table scan, and this endpoint is unauthenticated,
    // so an attacker could otherwise force repeated scans and read the live device total.
    res.json({ ok: true, lastDispatchAt: stats().lastDispatchAt });
  });

  // eslint-disable-next-line no-unused-vars
  app.use((err, req, res, next) => {
    if (err?.type === 'entity.parse.failed') return res.status(400).json({ error: 'invalid JSON body' });
    if (err?.type === 'entity.too.large') return res.status(413).json({ error: 'body too large (4kb limit)' });
    console.error(`unhandled error: ${err?.stack ?? err}`);
    res.status(500).json({ error: 'internal error' });
  });

  return app;
}
