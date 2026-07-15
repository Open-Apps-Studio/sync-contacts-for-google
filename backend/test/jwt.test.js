import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, verify as cryptoVerify } from 'node:crypto';
import { createJwtProvider } from '../src/apns.js';

function makeKeyPair() {
  return generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
}

function decodeSegment(segment) {
  return JSON.parse(Buffer.from(segment, 'base64url').toString('utf8'));
}

test('JWT has ES256 header, APNs claims, and a valid P-1363 signature', () => {
  const { privateKey, publicKey } = makeKeyPair();
  const nowMs = 1_752_537_600_000; // fixed clock
  const getJwt = createJwtProvider({
    key: privateKey.export({ type: 'pkcs8', format: 'pem' }),
    keyId: 'ABC123DEFG',
    teamId: 'TEAMID1234',
    now: () => nowMs,
  });

  const jwt = getJwt();
  const parts = jwt.split('.');
  assert.equal(parts.length, 3);

  const header = decodeSegment(parts[0]);
  assert.deepEqual(header, { alg: 'ES256', kid: 'ABC123DEFG' });

  const claims = decodeSegment(parts[1]);
  assert.deepEqual(claims, { iss: 'TEAMID1234', iat: Math.floor(nowMs / 1000) });

  const signature = Buffer.from(parts[2], 'base64url');
  assert.equal(signature.length, 64, 'ES256 JOSE signature is raw r||s (64 bytes)');
  const valid = cryptoVerify(
    'sha256',
    Buffer.from(`${parts[0]}.${parts[1]}`),
    { key: publicKey, dsaEncoding: 'ieee-p1363' },
    signature,
  );
  assert.ok(valid, 'signature verifies with the public key');
});

test('JWT is cached for ~45 minutes and refreshed after', () => {
  const { privateKey } = makeKeyPair();
  let nowMs = 1_752_537_600_000;
  const getJwt = createJwtProvider({
    key: privateKey.export({ type: 'pkcs8', format: 'pem' }),
    keyId: 'ABC123DEFG',
    teamId: 'TEAMID1234',
    now: () => nowMs,
  });

  const first = getJwt();
  nowMs += 44 * 60 * 1000; // still inside cache window
  assert.equal(getJwt(), first, 'token reused within 45 minutes');

  nowMs += 2 * 60 * 1000; // 46 minutes total
  const refreshed = getJwt();
  assert.notEqual(refreshed, first, 'token re-signed after 45 minutes');
  const claims = decodeSegment(refreshed.split('.')[1]);
  assert.equal(claims.iat, Math.floor(nowMs / 1000), 'refreshed token carries new iat');
});
