import test from 'node:test';
import assert from 'node:assert/strict';
import { createDispatcher } from '../src/dispatcher.js';
import { MemoryDeviceStore } from '../src/store/memory.js';

const silentLog = { log() {}, warn() {}, error() {} };

/** Fake clock advanced manually by tests. */
function fakeClock(startMs = 1_000_000_000_000) {
  let t = startMs;
  const now = () => t;
  now.advanceMinutes = (min) => {
    t += min * 60_000;
  };
  return now;
}

/** Fake APNs client that records sends and replies per configured responses. */
function fakeApns(responsesByToken = {}) {
  return {
    sent: [],
    inFlight: 0,
    maxInFlight: 0,
    async send(token) {
      this.inFlight += 1;
      this.maxInFlight = Math.max(this.maxInFlight, this.inFlight);
      await new Promise((r) => setImmediate(r));
      this.inFlight -= 1;
      this.sent.push(token);
      const response = responsesByToken[token];
      if (response instanceof Error) throw response;
      return response ?? { status: 200, reason: null };
    },
  };
}

function makeDispatcher({ store, apns, now }) {
  return createDispatcher({ store, apns, now, log: silentLog });
}

test('pushes devices that have never been pushed and records lastPushAt', async () => {
  const store = new MemoryDeviceStore();
  await store.upsert({ token: 'aa'.repeat(32), cadenceMinutes: 20 });
  const now = fakeClock();
  const apns = fakeApns();
  const dispatcher = makeDispatcher({ store, apns, now });

  const result = await dispatcher.runOnce();
  assert.deepEqual([result.due, result.sent], [1, 1]);
  assert.equal((await store.get('aa'.repeat(32))).lastPushAt, now());
  assert.equal(dispatcher.lastDispatchAt, new Date(now()).toISOString());
});

test('respects per-device cadence based on lastPushAt', async () => {
  const store = new MemoryDeviceStore();
  const fast = 'aa'.repeat(32); // 15 min cadence
  const slow = 'bb'.repeat(32); // 240 min cadence
  await store.upsert({ token: fast, cadenceMinutes: 15 });
  await store.upsert({ token: slow, cadenceMinutes: 240 });
  const now = fakeClock();
  const apns = fakeApns();
  const dispatcher = makeDispatcher({ store, apns, now });

  await dispatcher.runOnce(); // both never pushed -> both sent
  assert.deepEqual(apns.sent.sort(), [fast, slow].sort());

  apns.sent = [];
  now.advanceMinutes(10); // neither cadence elapsed
  assert.equal((await dispatcher.runOnce()).due, 0);
  assert.deepEqual(apns.sent, []);

  now.advanceMinutes(10); // 20 min since push: only the 15-min device is due
  await dispatcher.runOnce();
  assert.deepEqual(apns.sent, [fast]);

  apns.sent = [];
  now.advanceMinutes(230); // long past 240 min for the slow device
  await dispatcher.runOnce();
  assert.ok(apns.sent.includes(slow));
});

test('prunes devices on 410/Unregistered and BadDeviceToken', async () => {
  const store = new MemoryDeviceStore();
  const gone = 'aa'.repeat(32);
  const bad = 'bb'.repeat(32);
  const good = 'cc'.repeat(32);
  await store.upsert({ token: gone, cadenceMinutes: 20 });
  await store.upsert({ token: bad, cadenceMinutes: 20 });
  await store.upsert({ token: good, cadenceMinutes: 20 });
  const apns = fakeApns({
    [gone]: { status: 410, reason: 'Unregistered' },
    [bad]: { status: 400, reason: 'BadDeviceToken' },
  });
  const dispatcher = makeDispatcher({ store, apns, now: fakeClock() });

  const result = await dispatcher.runOnce();
  assert.equal(result.pruned, 2);
  assert.equal(result.sent, 1);
  assert.equal(await store.get(gone), null);
  assert.equal(await store.get(bad), null);
  assert.ok(await store.get(good));
});

test('keeps devices on 429/5xx and transport errors, retries next cycle', async () => {
  const store = new MemoryDeviceStore();
  const throttled = 'aa'.repeat(32);
  const flaky = 'bb'.repeat(32);
  const broken = 'cc'.repeat(32);
  await store.upsert({ token: throttled, cadenceMinutes: 20 });
  await store.upsert({ token: flaky, cadenceMinutes: 20 });
  await store.upsert({ token: broken, cadenceMinutes: 20 });
  const now = fakeClock();
  const responses = {
    [throttled]: { status: 429, reason: 'TooManyRequests' },
    [flaky]: { status: 503, reason: 'ServiceUnavailable' },
    [broken]: new Error('GOAWAY'),
  };
  const apns = fakeApns(responses);
  const dispatcher = makeDispatcher({ store, apns, now });

  const first = await dispatcher.runOnce();
  assert.equal(first.deferred, 3);
  assert.equal(await store.count(), 3);
  for (const token of [throttled, flaky, broken]) {
    assert.equal((await store.get(token)).lastPushAt, null, 'lastPushAt must stay null after failure');
  }

  // Next cycle they are still due (lastPushAt never set) and succeed this time.
  delete responses[throttled];
  delete responses[flaky];
  delete responses[broken];
  now.advanceMinutes(20);
  const second = await dispatcher.runOnce();
  assert.equal(second.sent, 3);
  assert.equal(second.due, 3);
});

test('no-ops safely when APNs is not configured', async () => {
  const store = new MemoryDeviceStore();
  await store.upsert({ token: 'aa'.repeat(32), cadenceMinutes: 20 });
  const warnings = [];
  const dispatcher = createDispatcher({
    store,
    apns: null,
    log: { log() {}, warn: (msg) => warnings.push(msg), error() {} },
  });

  const result = await dispatcher.runOnce();
  await dispatcher.runOnce();
  assert.deepEqual(result, { due: 0, sent: 0, pruned: 0, deferred: 0 });
  assert.equal(warnings.filter((w) => w.includes('APNs not configured')).length, 1, 'warn once only');
  assert.equal((await store.get('aa'.repeat(32))).lastPushAt, null);
});

test('limits send concurrency', async () => {
  const store = new MemoryDeviceStore();
  for (let i = 0; i < 25; i++) {
    await store.upsert({ token: i.toString(16).padStart(64, '0'), cadenceMinutes: 20 });
  }
  const apns = fakeApns();
  const dispatcher = createDispatcher({ store, apns, concurrency: 10, now: fakeClock(), log: silentLog });

  const result = await dispatcher.runOnce();
  assert.equal(result.sent, 25);
  assert.ok(apns.maxInFlight <= 10, `max in-flight was ${apns.maxInFlight}, expected <= 10`);
});

test('start() schedules periodic cycles and stop() halts them', async () => {
  const store = new MemoryDeviceStore();
  await store.upsert({ token: 'aa'.repeat(32), cadenceMinutes: 15 });
  const apns = fakeApns();
  // Real timers with a tiny interval; real clock so cadence blocks re-sends.
  const dispatcher = createDispatcher({ store, apns, intervalMs: 20, log: silentLog });

  dispatcher.start();
  await new Promise((r) => setTimeout(r, 80));
  dispatcher.stop();
  assert.equal(apns.sent.length, 1, 'sent once immediately, then cadence-gated');
  assert.ok(dispatcher.lastDispatchAt, 'lastDispatchAt is set');

  const cyclesWhenStopped = apns.sent.length;
  await new Promise((r) => setTimeout(r, 60));
  assert.equal(apns.sent.length, cyclesWhenStopped, 'no cycles after stop()');
});
