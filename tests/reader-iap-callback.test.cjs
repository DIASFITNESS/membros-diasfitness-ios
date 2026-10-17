// Exercises the actual JavaScript embedded in Swift. No StoreKit calls or network.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const root = path.join(__dirname, '..');
const bridgePath = 'src/Membros Diasfitness/ReaderIAPBridge.swift';
const source = fs.readFileSync(path.join(root, bridgePath), 'utf8');
const controller = fs.readFileSync(path.join(root, 'src/Membros Diasfitness/ViewController.swift'), 'utf8');
const scripts = [...source.matchAll(/let script = """\n([\s\S]*?)\n        """/g)].map(m => m[1]);
assert.equal(scripts.length, 2);
const tokenA = '11111111-1111-4111-8111-111111111111';
const tokenB = '22222222-2222-4222-8222-222222222222';
function page(origin = 'https://reader.diasfitness.com') {
  const window = { location: { origin } };
  window.top = window;
  return { window, document: {} };
}
function capture(page, candidate = tokenA) {
  return vm.runInNewContext(scripts[0].replace('\\(candidate)', candidate), page);
}
function deliver(page, token, id = 'request-1', result = { ok: true, data: { signedTransaction: 'synthetic-jws', transactionId: '9007199254740993' } }) {
  const values = { tokenJSON: JSON.stringify(token), idJSON: JSON.stringify(id), resultJSON: JSON.stringify(result) };
  const script = scripts[1].replace(/\\\((tokenJSON|idJSON|resultJSON)\)/g, (_, key) => values[key]);
  return vm.runInNewContext(script, page);
}
test('normal callback preserves ID, envelope, JWS and string transaction ID exactly once', () => {
  const p = page(); const token = capture(p); const calls = [];
  p.window.__diasIAPResolve = (...args) => calls.push(args);
  assert.equal(deliver(p, token), 'delivered');
  assert.deepEqual(JSON.parse(JSON.stringify(calls)), [['request-1', { ok: true, data: { signedTransaction: 'synthetic-jws', transactionId: '9007199254740993' } }]]);
});
test('missing and non-function resolvers are reported', () => {
  for (const resolver of [undefined, null, true, 'callback', {}]) {
    const p = page(); const token = capture(p); p.window.__diasIAPResolve = resolver;
    assert.equal(deliver(p, token), 'resolver_unavailable');
  }
});
test('synchronous resolver exception returns only a fixed diagnostic code', () => {
  const p = page(); const token = capture(p); let count = 0;
  p.window.__diasIAPResolve = () => { count++; throw new Error('sensitive synthetic message'); };
  assert.equal(deliver(p, token), 'resolver_threw'); assert.equal(count, 1);
});
test('execution error outside resolver propagates to the host evaluator (native error path)', () => {
  const p = page(); const token = capture(p);
  Object.defineProperty(p.window, '__diasIAPResolve', { get() { throw new Error('synthetic evaluation error'); } });
  assert.throws(() => deliver(p, token), /synthetic evaluation error/);
});
test('same-origin document replacement during an outstanding operation receives no old result', () => {
  const old = page(); const oldToken = capture(old); const replacement = page(); let calls = 0;
  replacement.window.__diasIAPResolve = () => calls++;
  assert.equal(deliver(replacement, oldToken), 'document_changed');
  assert.equal(capture(replacement, tokenB), tokenB);
  assert.equal(deliver(replacement, oldToken), 'document_changed');
  assert.equal(calls, 0);
});
test('new document can issue its own correlated restore using the unchanged envelope', () => {
  const p = page(); const token = capture(p, tokenB); const calls = [];
  p.window.__diasIAPResolve = (...args) => calls.push(args);
  const result = { ok: true, data: { entitlements: [{ signedTransaction: 'synthetic-recovered-jws', transactionId: '123', originalTransactionId: '123' }] } };
  assert.equal(deliver(p, token, 'restore-new-document', result), 'delivered');
  assert.deepEqual(JSON.parse(JSON.stringify(calls)), [['restore-new-document', result]]);
});
test('foreign origin and iframe are rejected without invoking resolver', () => {
  for (const foreign of [true, false]) {
    const p = page(); const token = capture(p); let calls = 0;
    p.window.__diasIAPResolve = () => calls++;
    if (foreign) p.window.location.origin = 'https://example.invalid'; else p.window.top = {};
    assert.equal(deliver(p, token), 'origin_rejected'); assert.equal(calls, 0);
    assert.equal(capture(p), null);
  }
});
test('document token is stable across concurrent requests and cannot be overwritten', () => {
  const p = page(); assert.equal(capture(p), tokenA); assert.equal(capture(p, tokenB), tokenA);
  assert.throws(() => Object.defineProperty(p.document, '__diasIAPDocumentToken', { value: tokenB }), TypeError);
});
test('JSON-special IDs and error envelopes are passed as data, never executable code', () => {
  const p = page(); const token = capture(p); const calls = [];
  p.window.__diasIAPResolve = (...args) => calls.push(args);
  const id = '\"\\\n); window.injected = true; //';
  const result = { ok: false, error: { code: 'user_cancelled', message: 'Aspas " e quebra\n de linha' } };
  assert.equal(deliver(p, token, id, result), 'delivered');
  assert.equal(p.window.injected, undefined);
  assert.deepEqual(JSON.parse(JSON.stringify(calls)), [[id, result]]);
});
test('undefined resolver return remains compatible; delivered is invocation, not backend approval', () => {
  const p = page(); const token = capture(p); p.window.__diasIAPResolve = () => undefined;
  assert.equal(deliver(p, token), 'delivered');
});
// Static regression checks below are NOT execution of Swift, WKWebView or StoreKit.
test('static: native handles evaluation errors and missing acknowledgements without logging payloads', () => {
  const callback = source.slice(source.indexOf('private func sendJavaScriptCallback'), source.indexOf('private func diagnose'));
  assert.match(callback, /if error != nil \{\s*self\?\.diagnose\(\.evaluationFailed\)/);
  assert.match(callback, /diagnose\(\.acknowledgementMissing\)/);
  assert.doesNotMatch(callback, /completionHandler: nil|\.purchase\(|\.finish\(|pendingTransactions\.remove/);
  const logger = source.slice(source.indexOf('private func diagnose'), source.indexOf('private enum BridgeError'));
  assert.match(logger, /failure\.rawValue/);
  assert.doesNotMatch(logger, /localizedDescription|requestID|transactionId|resultJSON|signedTransaction/);
});
test('static: native binds original view and generation and invalidates on navigation/process loss', () => {
  assert.match(source, /sourceWebView === webViewProvider\(\)/);
  assert.match(source, /context\.generation == documentGeneration/);
  for (const delegate of ['didStartProvisionalNavigation', 'webViewWebContentProcessDidTerminate']) {
    const method = controller.slice(controller.indexOf(delegate), controller.indexOf(delegate) + 200);
    assert.match(method, /iapBridge\.documentWillChange\(in: webView\)/);
  }
});
test('static: recovery and cryptographic verification remain unchanged from audited base', () => {
  // SHA-256 of unchanged blocks at audited commit 00dc8d3882c2ed3d1503303790ddef5a210cf7b4.
  const digest = value => crypto.createHash('sha256').update(value).digest('hex');
  const between = (s, start, end) => s.slice(s.indexOf(start), s.indexOf(end));
  assert.equal(digest(between(source, 'private func appendRecovery', '    // Called for provisional')), '9620d89a8c38c0c92c4d056bfd226b18375fe106f12355d94f03690d9634b420');
  const normalize = s => s.replaceAll('await respond(requestID, context: context,', 'respond(requestID,');
  assert.equal(digest(normalize(between(source, 'case "restore", "sync":', '            case "finish":'))), '03ce36616d2240a7a787e61a9aac69ef2853bb4c43d3708b138a4e7d0edd1a96');
  assert.equal((source.match(/await transaction\.finish\(\)/g) || []).length, 1);
  const finish = between(source, 'case "finish":', '            default:');
  assert.match(finish, /await transaction\.finish\(\)/);
  assert.doesNotMatch(between(source, 'case "purchase":', 'case "restore", "sync":'), /\.finish\(/);
});
