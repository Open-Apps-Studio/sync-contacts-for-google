import http2 from 'node:http2';
import { createPrivateKey, sign as cryptoSign } from 'node:crypto';

const JWT_MAX_AGE_MS = 45 * 60 * 1000; // Apple accepts 20-60 min; refresh at 45
const REQUEST_TIMEOUT_MS = 30_000;
const BACKGROUND_PAYLOAD = JSON.stringify({ aps: { 'content-available': 1 } });

const b64url = (input) => Buffer.from(input).toString('base64url');

/**
 * Returns a function that yields a cached ES256 provider JWT for APNs,
 * re-signing when the cached one is ~45 minutes old.
 *
 * Header: { alg: 'ES256', kid }  Claims: { iss: teamId, iat }
 * Signature: raw r||s (ieee-p1363), as JOSE requires — not DER.
 */
export function createJwtProvider({ key, keyId, teamId, now = Date.now, maxAgeMs = JWT_MAX_AGE_MS }) {
  const privateKey = createPrivateKey(key);
  let cached = null;
  let issuedAtMs = 0;

  return function getJwt() {
    const t = now();
    if (cached && t - issuedAtMs < maxAgeMs) return cached;
    const header = b64url(JSON.stringify({ alg: 'ES256', kid: keyId }));
    const claims = b64url(JSON.stringify({ iss: teamId, iat: Math.floor(t / 1000) }));
    const signingInput = `${header}.${claims}`;
    const signature = cryptoSign('sha256', Buffer.from(signingInput), {
      key: privateKey,
      dsaEncoding: 'ieee-p1363',
    });
    cached = `${signingInput}.${b64url(signature)}`;
    issuedAtMs = t;
    return cached;
  };
}

/**
 * Minimal APNs client over a single node:http2 session.
 *
 * - Lazily connects; transparently reconnects after GOAWAY, errors, or close.
 * - send(token) resolves { status, reason } (reason from APNs' JSON error
 *   body, e.g. 'Unregistered', 'BadDeviceToken') and rejects only on
 *   transport-level failures.
 */
export class ApnsClient {
  #host;
  #topic;
  #getJwt;
  #session = null;

  constructor({ key, keyId, teamId, topic, host = 'api.push.apple.com', now = Date.now }) {
    this.#host = host;
    this.#topic = topic;
    this.#getJwt = createJwtProvider({ key, keyId, teamId, now });
  }

  #getSession() {
    const current = this.#session;
    if (current && !current.closed && !current.destroyed) return current;

    const session = http2.connect(`https://${this.#host}:443`);
    const forget = () => {
      if (this.#session === session) this.#session = null;
    };
    session.on('error', forget);
    session.on('close', forget);
    session.on('goaway', () => {
      forget();
      session.close();
    });
    this.#session = session;
    return session;
  }

  /**
   * Send a silent background push. Returns { status, reason } where status is
   * the HTTP/2 status from APNs (200 = accepted).
   */
  async send(token) {
    const session = this.#getSession();
    const jwt = this.#getJwt();

    return new Promise((resolve, reject) => {
      let settled = false;
      const fail = (err) => {
        if (settled) return;
        settled = true;
        reject(err);
      };

      let req;
      try {
        req = session.request({
          ':method': 'POST',
          ':path': `/3/device/${token}`,
          authorization: `bearer ${jwt}`,
          'apns-topic': this.#topic,
          'apns-push-type': 'background',
          'apns-priority': '5',
          'content-type': 'application/json',
        });
      } catch (err) {
        // Session died between checks — drop it so the next call reconnects.
        if (this.#session === session) this.#session = null;
        fail(err);
        return;
      }

      let status = 0;
      let body = '';
      req.setEncoding('utf8');
      req.setTimeout(REQUEST_TIMEOUT_MS, () => {
        req.close(http2.constants.NGHTTP2_CANCEL);
        fail(new Error(`APNs request timed out after ${REQUEST_TIMEOUT_MS}ms`));
      });
      req.on('response', (headers) => {
        status = headers[':status'];
      });
      req.on('data', (chunk) => {
        body += chunk;
      });
      req.on('error', fail);
      req.on('end', () => {
        if (settled) return;
        settled = true;
        let reason = null;
        if (body) {
          try {
            reason = JSON.parse(body).reason ?? null;
          } catch {
            reason = null;
          }
        }
        resolve({ status, reason });
      });
      req.end(BACKGROUND_PAYLOAD);
    });
  }

  close() {
    this.#session?.close();
    this.#session = null;
  }
}
