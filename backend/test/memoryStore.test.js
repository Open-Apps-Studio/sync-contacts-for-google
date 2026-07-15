import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { MemoryDeviceStore } from '../src/store/memory.js';

const TOKEN_A = 'aa'.repeat(32);
const TOKEN_B = 'bb'.repeat(32);

test('MemoryDeviceStore basic CRUD without a file', async () => {
  const store = new MemoryDeviceStore();
  await store.upsert({ token: TOKEN_A, cadenceMinutes: 20 });
  assert.equal(await store.count(), 1);
  assert.equal((await store.get(TOKEN_A)).cadenceMinutes, 20);

  await store.upsert({ token: TOKEN_A, cadenceMinutes: 60 });
  assert.equal(await store.count(), 1, 'upsert does not duplicate');
  assert.equal((await store.get(TOKEN_A)).cadenceMinutes, 60);

  await store.recordPush(TOKEN_A, 12345);
  assert.equal((await store.get(TOKEN_A)).lastPushAt, 12345);

  await store.remove(TOKEN_A);
  await store.remove(TOKEN_A); // idempotent
  assert.equal(await store.count(), 0);
  assert.equal(await store.get(TOKEN_A), null);
});

test('MemoryDeviceStore persists to a JSON file and loads it back', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'devstore-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const filePath = join(dir, 'nested', 'devices.json');

  const store = new MemoryDeviceStore({ filePath });
  await store.upsert({ token: TOKEN_A, cadenceMinutes: 30 });
  await store.upsert({ token: TOKEN_B, cadenceMinutes: 120 });
  await store.recordPush(TOKEN_A, 777);
  assert.ok(existsSync(filePath), 'file created (including parent dirs)');

  // Fresh instance from the same file sees the same data.
  const reloaded = new MemoryDeviceStore({ filePath });
  assert.equal(await reloaded.count(), 2);
  const a = await reloaded.get(TOKEN_A);
  assert.equal(a.cadenceMinutes, 30);
  assert.equal(a.lastPushAt, 777);
  assert.equal((await reloaded.get(TOKEN_B)).lastPushAt, null);

  // Deletions persist too.
  await reloaded.remove(TOKEN_B);
  const reloadedAgain = new MemoryDeviceStore({ filePath });
  assert.equal(await reloadedAgain.count(), 1);
  assert.equal(await reloadedAgain.get(TOKEN_B), null);
});

test('MemoryDeviceStore starts empty when the file does not exist yet', async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'devstore-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const store = new MemoryDeviceStore({ filePath: join(dir, 'missing.json') });
  assert.equal(await store.count(), 0);
});
