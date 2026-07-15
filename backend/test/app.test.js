import test from 'node:test';
import assert from 'node:assert/strict';
import { createApp } from '../src/app.js';
import { MemoryDeviceStore } from '../src/store/memory.js';

const VALID_TOKEN = 'a'.repeat(64);

async function startServer(deps = {}) {
  const store = deps.store ?? new MemoryDeviceStore();
  const app = createApp({ ...deps, store });
  const server = await new Promise((resolve) => {
    const s = app.listen(0, '127.0.0.1', () => resolve(s));
  });
  const base = `http://127.0.0.1:${server.address().port}`;
  return { store, server, base, close: () => new Promise((r) => server.close(r)) };
}

function postDevice(base, body) {
  return fetch(`${base}/v1/device`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
}

test('POST /v1/device registers a device with default cadence', async () => {
  const { store, base, close } = await startServer();
  try {
    const res = await postDevice(base, { token: VALID_TOKEN });
    assert.equal(res.status, 204);
    const device = await store.get(VALID_TOKEN);
    assert.ok(device);
    assert.equal(device.cadenceMinutes, 20);
    assert.equal(device.lastPushAt, null);
  } finally {
    await close();
  }
});

test('POST /v1/device accepts custom cadence and normalizes token case', async () => {
  const { store, base, close } = await startServer();
  try {
    const res = await postDevice(base, { token: 'AB'.repeat(32), cadenceMinutes: 60 });
    assert.equal(res.status, 204);
    const device = await store.get('ab'.repeat(32));
    assert.ok(device);
    assert.equal(device.cadenceMinutes, 60);
  } finally {
    await close();
  }
});

test('POST /v1/device is an upsert (no duplicates, cadence updated)', async () => {
  const { store, base, close } = await startServer();
  try {
    assert.equal((await postDevice(base, { token: VALID_TOKEN, cadenceMinutes: 30 })).status, 204);
    assert.equal((await postDevice(base, { token: VALID_TOKEN, cadenceMinutes: 45 })).status, 204);
    assert.equal(await store.count(), 1);
    assert.equal((await store.get(VALID_TOKEN)).cadenceMinutes, 45);
  } finally {
    await close();
  }
});

test('POST /v1/device rejects bad tokens and cadences with 400', async () => {
  const { store, base, close } = await startServer();
  try {
    const badBodies = [
      {}, // missing token
      { token: 12345 }, // not a string
      { token: 'a'.repeat(63) }, // too short
      { token: 'g'.repeat(64) }, // not hex
      { token: `${'a'.repeat(63)} ` }, // whitespace
      { token: VALID_TOKEN, cadenceMinutes: 14 }, // below min
      { token: VALID_TOKEN, cadenceMinutes: 241 }, // above max
      { token: VALID_TOKEN, cadenceMinutes: 20.5 }, // not an integer
      { token: VALID_TOKEN, cadenceMinutes: '20' }, // not a number
    ];
    for (const body of badBodies) {
      const res = await postDevice(base, body);
      assert.equal(res.status, 400, `expected 400 for ${JSON.stringify(body)}`);
    }
    assert.equal(await store.count(), 0);
  } finally {
    await close();
  }
});

test('POST /v1/device rejects malformed JSON with 400 and oversized bodies with 413', async () => {
  const { base, close } = await startServer();
  try {
    const bad = await fetch(`${base}/v1/device`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: '{not json',
    });
    assert.equal(bad.status, 400);

    const big = await postDevice(base, { token: VALID_TOKEN, junk: 'x'.repeat(8192) });
    assert.equal(big.status, 413);
  } finally {
    await close();
  }
});

test('DELETE /v1/device/:token removes the device and is idempotent', async () => {
  const { store, base, close } = await startServer();
  try {
    await postDevice(base, { token: VALID_TOKEN });
    assert.equal(await store.count(), 1);

    const first = await fetch(`${base}/v1/device/${VALID_TOKEN.toUpperCase()}`, { method: 'DELETE' });
    assert.equal(first.status, 204);
    assert.equal(await store.count(), 0);

    const second = await fetch(`${base}/v1/device/${VALID_TOKEN}`, { method: 'DELETE' });
    assert.equal(second.status, 204);
  } finally {
    await close();
  }
});

test('GET /healthz reports device count and lastDispatchAt', async () => {
  const stamp = '2026-07-15T00:00:00.000Z';
  const { base, close } = await startServer({ stats: () => ({ lastDispatchAt: stamp }) });
  try {
    await postDevice(base, { token: VALID_TOKEN });
    const res = await fetch(`${base}/healthz`);
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { ok: true, devices: 1, lastDispatchAt: stamp });
  } finally {
    await close();
  }
});

test('security headers are present and x-powered-by is not', async () => {
  const { base, close } = await startServer();
  try {
    const res = await fetch(`${base}/healthz`);
    assert.equal(res.headers.get('x-content-type-options'), 'nosniff');
    assert.equal(res.headers.get('x-frame-options'), 'DENY');
    assert.equal(res.headers.get('referrer-policy'), 'no-referrer');
    assert.ok(res.headers.get('content-security-policy'));
    assert.ok(res.headers.get('strict-transport-security'));
    assert.equal(res.headers.get('x-powered-by'), null);
  } finally {
    await close();
  }
});
