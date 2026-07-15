import { createHmac } from 'node:crypto';

/**
 * DeviceStore backed by Azure Table Storage via the REST API — no SDK.
 *
 * Auth: SharedKeyLite (AZURE_TABLES_KEY) or a table SAS (AZURE_TABLES_SAS).
 * All devices live under PartitionKey 'device' with RowKey = the APNs token
 * (hex, so no OData key escaping is needed).
 *
 * Timestamps are stored as strings (Azure Tables' unannotated JSON integers
 * are Int32, too small for epoch milliseconds) and parsed back to numbers.
 */

const API_VERSION = '2019-02-02';
const PARTITION = 'device';

export class AzureTableDeviceStore {
  #account;
  #key;
  #sas;
  #table;
  #fetch;
  #ready = false;

  constructor({ account, key = null, sas = null, table = 'devices', fetchImpl = fetch }) {
    if (!account) throw new Error('AzureTableDeviceStore requires an account');
    if (!key && !sas) throw new Error('AzureTableDeviceStore requires a key or a SAS token');
    this.#account = account;
    this.#key = key;
    this.#sas = sas ? sas.replace(/^\?/, '') : null;
    this.#table = table;
    this.#fetch = fetchImpl;
  }

  #url(resource, query = {}) {
    const url = new URL(`https://${this.#account}.table.core.windows.net/${resource}`);
    for (const [k, v] of Object.entries(query)) url.searchParams.set(k, v);
    if (this.#sas) {
      const joined = url.search ? `${url.search}&${this.#sas}` : `?${this.#sas}`;
      return `${url.origin}${url.pathname}${joined}`;
    }
    return url.toString();
  }

  /** SharedKeyLite for the Table service: sign `x-ms-date + "\n" + canonicalized resource`. */
  #headers(resource, { hasBody = false } = {}) {
    const headers = {
      'x-ms-date': new Date().toUTCString(),
      'x-ms-version': API_VERSION,
      accept: 'application/json;odata=nometadata',
      dataserviceversion: '3.0;NetFx',
    };
    if (hasBody) headers['content-type'] = 'application/json';
    if (this.#key && !this.#sas) {
      const stringToSign = `${headers['x-ms-date']}\n/${this.#account}/${resource}`;
      const signature = createHmac('sha256', Buffer.from(this.#key, 'base64'))
        .update(stringToSign, 'utf8')
        .digest('base64');
      headers.authorization = `SharedKeyLite ${this.#account}:${signature}`;
    }
    return headers;
  }

  async #request(method, resource, { query = {}, body = null, extraHeaders = {} } = {}) {
    const headers = { ...this.#headers(resource, { hasBody: body !== null }), ...extraHeaders };
    const res = await this.#fetch(this.#url(resource, query), {
      method,
      headers,
      body: body === null ? undefined : JSON.stringify(body),
    });
    return res;
  }

  #entityResource(token) {
    return `${this.#table}(PartitionKey='${PARTITION}',RowKey='${token}')`;
  }

  /** Create the table if it does not exist. Called lazily before first use. */
  async init() {
    if (this.#ready) return;
    const res = await this.#request('POST', 'Tables', { body: { TableName: this.#table } });
    if (!res.ok && res.status !== 409) {
      throw new Error(`Azure Tables: failed to create table ${this.#table}: ${res.status} ${await res.text()}`);
    }
    this.#ready = true;
  }

  static #toEntity(device) {
    return {
      PartitionKey: PARTITION,
      RowKey: device.token,
      cadenceMinutes: device.cadenceMinutes,
      createdAt: String(device.createdAt),
      updatedAt: String(device.updatedAt),
      lastPushAt: device.lastPushAt === null ? '' : String(device.lastPushAt),
    };
  }

  static #fromEntity(entity) {
    return {
      token: entity.RowKey,
      cadenceMinutes: Number(entity.cadenceMinutes) || 20,
      createdAt: Number(entity.createdAt) || 0,
      updatedAt: Number(entity.updatedAt) || 0,
      lastPushAt: entity.lastPushAt ? Number(entity.lastPushAt) : null,
    };
  }

  async upsert({ token, cadenceMinutes }) {
    await this.init();
    const existing = await this.get(token);
    const now = Date.now();
    const device = {
      token,
      cadenceMinutes,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
      lastPushAt: existing?.lastPushAt ?? null,
    };
    // Insert Or Merge Entity: HTTP MERGE on the entity URL.
    const res = await this.#request('MERGE', this.#entityResource(token), {
      body: AzureTableDeviceStore.#toEntity(device),
    });
    if (!res.ok) {
      throw new Error(`Azure Tables: upsert failed: ${res.status} ${await res.text()}`);
    }
    return device;
  }

  async remove(token) {
    await this.init();
    const res = await this.#request('DELETE', this.#entityResource(token), {
      extraHeaders: { 'if-match': '*' },
    });
    if (!res.ok && res.status !== 404) {
      throw new Error(`Azure Tables: delete failed: ${res.status} ${await res.text()}`);
    }
  }

  async get(token) {
    await this.init();
    const res = await this.#request('GET', this.#entityResource(token));
    if (res.status === 404) return null;
    if (!res.ok) throw new Error(`Azure Tables: get failed: ${res.status} ${await res.text()}`);
    return AzureTableDeviceStore.#fromEntity(await res.json());
  }

  async all() {
    await this.init();
    const devices = [];
    // Paginate with continuation tokens; note the canonicalized resource for
    // signing never includes the $filter/continuation query string.
    let continuation = null;
    do {
      const query = { $filter: `PartitionKey eq '${PARTITION}'` };
      if (continuation) {
        if (continuation.nextPartitionKey) query.NextPartitionKey = continuation.nextPartitionKey;
        if (continuation.nextRowKey) query.NextRowKey = continuation.nextRowKey;
      }
      const res = await this.#request('GET', `${this.#table}()`, { query });
      if (!res.ok) throw new Error(`Azure Tables: query failed: ${res.status} ${await res.text()}`);
      const data = await res.json();
      for (const entity of data.value ?? []) devices.push(AzureTableDeviceStore.#fromEntity(entity));
      const nextPartitionKey = res.headers.get('x-ms-continuation-nextpartitionkey');
      const nextRowKey = res.headers.get('x-ms-continuation-nextrowkey');
      continuation = nextPartitionKey || nextRowKey ? { nextPartitionKey, nextRowKey } : null;
    } while (continuation);
    return devices;
  }

  async count() {
    return (await this.all()).length;
  }

  async recordPush(token, epochMs) {
    await this.init();
    const res = await this.#request('MERGE', this.#entityResource(token), {
      body: { PartitionKey: PARTITION, RowKey: token, lastPushAt: String(epochMs) },
      extraHeaders: { 'if-match': '*' },
    });
    if (!res.ok && res.status !== 404) {
      throw new Error(`Azure Tables: recordPush failed: ${res.status} ${await res.text()}`);
    }
  }
}
