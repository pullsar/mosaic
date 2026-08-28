import assert from 'node:assert/strict';
import {test} from 'node:test';
import {signS3RequestV4} from '../src/s3_sigv4.js';

const accessKeyId = 'AKIAIOSFODNN7EXAMPLE';
const secretAccessKey = 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY';
const now = new Date('2013-05-24T00:00:00.000Z');
const emptySha256 = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

test('SigV4 matches the AWS S3 GET Object calculation vector', () => {
  const signed = signS3RequestV4({
    method: 'GET',
    url: new URL('https://examplebucket.s3.amazonaws.com/test.txt'),
    region: 'us-east-1',
    accessKeyId,
    secretAccessKey,
    payloadSha256: emptySha256,
    headers: {range: 'bytes=0-9'},
    now,
  });

  assert.equal(
    signed.authorization,
    'AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,' +
      'SignedHeaders=host;range;x-amz-content-sha256;x-amz-date,' +
      'Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41',
  );
  assert.equal(signed.headers['x-amz-date'], '20130524T000000Z');
  assert.equal(signed.headers['x-amz-content-sha256'], emptySha256);
});

test('SigV4 matches the AWS S3 PUT Object calculation vector', () => {
  const signed = signS3RequestV4({
    method: 'PUT',
    url: new URL('https://examplebucket.s3.amazonaws.com/test%24file.text'),
    region: 'us-east-1',
    accessKeyId,
    secretAccessKey,
    payloadSha256: '44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072',
    headers: {
      date: 'Fri, 24 May 2013 00:00:00 GMT',
      'x-amz-storage-class': 'REDUCED_REDUNDANCY',
    },
    now,
  });

  assert.equal(
    signed.authorization,
    'AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,' +
      'SignedHeaders=date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class,' +
      'Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd',
  );
});

test('SigV4 includes session credentials and rejects mutable URL components', () => {
  const signed = signS3RequestV4({
    method: 'HEAD',
    url: new URL('https://storage.example.test/bucket/object'),
    region: 'auto',
    accessKeyId: 'ACCESS123',
    secretAccessKey: 'secret/with+symbols=',
    sessionToken: 'token/with+symbols=',
    payloadSha256: emptySha256,
    now,
  });
  assert.equal(signed.headers['x-amz-security-token'], 'token/with+symbols=');
  assert.match(signed.signedHeaders, /x-amz-security-token/);

  assert.throws(
    () => signS3RequestV4({
      method: 'GET',
      url: new URL('http://storage.example.test/object'),
      region: 'auto',
      accessKeyId: 'ACCESS123',
      secretAccessKey: 'secret',
      payloadSha256: emptySha256,
      now,
    }),
    /HTTPS/,
  );
  assert.throws(
    () => signS3RequestV4({
      method: 'GET',
      url: new URL('https://storage.example.test/object?version=1'),
      region: 'auto',
      accessKeyId: 'ACCESS123',
      secretAccessKey: 'secret',
      payloadSha256: emptySha256,
      now,
    }),
    /query strings/,
  );
});
