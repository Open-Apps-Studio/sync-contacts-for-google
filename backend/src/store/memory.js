import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';

/**
 * DeviceStore interface (all methods async):
 *   upsert({ token, cadenceMinutes }) -> device   register/refresh a device
 *   remove(token) -> void                         idempotent delete
 *   get(token) -> device | null
 *   all() -> device[]
 *   count() -> number
 *   recordPush(token, epochMs) -> void            set lastPushAt after a 200 from APNs
 *
 * Device shape: { token, cadenceMinutes, createdAt, updatedAt, lastPushAt }
 * (timestamps are epoch milliseconds; lastPushAt is null until the first push)
 */

export class MemoryDeviceStore {
  #devices = new Map();
  #filePath;

  /**
   * @param {{ filePath?: string|null }} [opts] - when filePath is set, the
   *   store persists to that JSON file after every mutation and loads from it
   *   on construction, so devices survive restarts on a single instance.
   */
  constructor({ filePath = null } = {}) {
    this.#filePath = filePath;
    if (filePath) this.#load();
  }

  #load() {
    let raw;
    try {
      raw = readFileSync(this.#filePath, 'utf8');
    } catch (err) {
      if (err.code === 'ENOENT') return; // first run: file appears on first write
      throw err;
    }
    const data = JSON.parse(raw);
    for (const device of data.devices ?? []) {
      if (device?.token) this.#devices.set(device.token, device);
    }
  }

  #save() {
    if (!this.#filePath) return;
    mkdirSync(dirname(this.#filePath), { recursive: true });
    const tmp = `${this.#filePath}.tmp`;
    writeFileSync(tmp, JSON.stringify({ devices: [...this.#devices.values()] }, null, 2));
    renameSync(tmp, this.#filePath); // atomic swap so a crash never truncates the store
  }

  async upsert({ token, cadenceMinutes }) {
    const now = Date.now();
    const existing = this.#devices.get(token);
    const device = {
      token,
      cadenceMinutes,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
      lastPushAt: existing?.lastPushAt ?? null,
    };
    this.#devices.set(token, device);
    this.#save();
    return device;
  }

  async remove(token) {
    if (this.#devices.delete(token)) this.#save();
  }

  async get(token) {
    return this.#devices.get(token) ?? null;
  }

  async all() {
    return [...this.#devices.values()];
  }

  async count() {
    return this.#devices.size;
  }

  async recordPush(token, epochMs) {
    const device = this.#devices.get(token);
    if (!device) return;
    device.lastPushAt = epochMs;
    this.#save();
  }
}
