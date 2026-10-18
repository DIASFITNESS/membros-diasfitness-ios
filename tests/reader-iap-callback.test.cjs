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
test('static: cryptographic verification and recovery response contract remain intact', () => {
  // SHA-256 of unchanged blocks at audited commit 00dc8d3882c2ed3d1503303790ddef5a210cf7b4.
  const digest = value => crypto.createHash('sha256').update(value).digest('hex');
  const between = (s, start, end) => s.slice(s.indexOf(start), s.indexOf(end));
  assert.equal(digest(between(source, 'private func verified<T>', '    // Called for provisional')), '10da04667932dfb4a743a62d432c94f7edcfd24558db46a6b5048f788b038bdd');
  const normalize = s => s.replaceAll('await respond(requestID, context: context,', 'respond(requestID,');
  assert.equal(digest(normalize(between(source, 'case "restore", "sync":', '            case "finish":'))), '03ce36616d2240a7a787e61a9aac69ef2853bb4c43d3708b138a4e7d0edd1a96');
  assert.equal((source.match(/await transaction\.finish\(\)/g) || []).length, 1);
  const finish = between(source, 'case "finish":', '            default:');
  assert.match(finish, /await transaction\.finish\(\)/);
  assert.doesNotMatch(between(source, 'case "purchase":', 'case "restore", "sync":'), /\.finish\(/);
});

// These fixtures exercise the REAL callback JS, not Product.products or purchase.
const existingIDs = [
  'com.diasfitness.reader.coreografias_fitness',
  'com.diasfitness.reader.alongamento',
  'com.diasfitness.reader.avaliacao_funcional'
];
const gapID = 'com.diasfitness.reader.gap';
const catalog26 = [...existingIDs, gapID,
  ...Array.from({ length: 22 }, (_, i) => `com.diasfitness.reader.synthetic_course_${i + 1}`)];
for (const [label, ids] of [
  ['three existing products', existingIDs], ['GAP', [gapID]],
  ['26 products (22 synthetic fixtures)', catalog26],
  ['future product without a native catalog entry', ['com.diasfitness.reader.future_course']]
]) {
  test(`callback simulation: ${label} preserves product fields`, () => {
    const p = page(); const token = capture(p); const calls = [];
    p.window.__diasIAPResolve = (...args) => calls.push(args);
    const result = { ok: true, data: { products: ids.map(id => ({
      id, title: id, description: 'Curso sintético', displayPrice: 'R$ 19,90'
    })) } };
    assert.equal(deliver(p, token, 'catalog', result), 'delivered');
    assert.deepEqual(JSON.parse(JSON.stringify(calls)), [['catalog', result]]);
  });
}
test('callback simulation: unavailable product yields an empty list without fabricated metadata', () => {
  const p = page(); const token = capture(p); let actual;
  p.window.__diasIAPResolve = (_, result) => { actual = result; };
  deliver(p, token, 'unavailable', { ok: true, data: { products: [] } });
  assert.deepEqual(JSON.parse(JSON.stringify(actual)), { ok: true, data: { products: [] } });
});
test('callback simulation: overlapping lookups retain their request IDs in reverse completion order', async () => {
  const p = page(); const token = capture(p); const calls = [];
  p.window.__diasIAPResolve = (...args) => calls.push(args);
  const first = { ok: true, data: { products: [{ id: gapID }] } };
  const second = { ok: true, data: { products: [{ id: existingIDs[0] }] } };
  let completeFirst;
  const pending = new Promise(resolve => { completeFirst = resolve; });
  const firstDelivery = pending.then(() => deliver(p, token, 'first', first));
  deliver(p, token, 'second', second);
  completeFirst(); await firstDelivery;
  assert.deepEqual(JSON.parse(JSON.stringify(calls)), [['second', second], ['first', first]]);
});
test('callback simulation: cancellation, pending and validation errors retain the existing envelope', () => {
  for (const code of ['user_cancelled', 'purchase_pending', 'iap_error']) {
    const p = page(); const token = capture(p); let actual;
    p.window.__diasIAPResolve = (_, result) => { actual = result; };
    const result = { ok: false, error: { code, message: 'Erro sintético' } };
    assert.equal(deliver(p, token, code, result), 'delivered');
    assert.deepEqual(JSON.parse(JSON.stringify(actual)), result);
  }
});
test('callback simulation: recovered new products preserve JWS and large transaction IDs', () => {
  const p = page(); const token = capture(p); let actual;
  p.window.__diasIAPResolve = (_, result) => { actual = result; };
  const result = { ok: true, data: { entitlements: [gapID, 'future'].map((id, i) => ({
    signedTransaction: `synthetic-jws-${id}`, transactionId: `900719925474099${i + 3}`,
    originalTransactionId: '9007199254740993'
  })) } };
  assert.equal(deliver(p, token, 'restore', result), 'delivered');
  assert.deepEqual(JSON.parse(JSON.stringify(actual)), result);
});

// Source-level guardrails below do not execute Swift or simulate Apple services.
const section = (start, end) => source.slice(source.indexOf(start), source.indexOf(end));
test('static: no native catalog, fallback IDs or shared product cache remain', () => {
  assert.doesNotMatch(source, /com\.diasfitness\.reader\.[A-Za-z0-9_]+|productsByID|\bproductIDs\b/);
  const get = section('case "getProducts":', 'case "purchase":');
  assert.match(get, /validatedProductIDs\(payload\["productIds"\]\)/);
  assert.match(get, /loadProducts\(for: requestedIDs\)/);
  assert.doesNotMatch(get, /\?\?/);
  const load = section('private func loadProducts', 'private func verified');
  assert.match(load, /Product\.products\(for: requestedIDs\.sorted\(\)\)/);
  assert.match(load, /requestedIDs\.contains\(\$0\.id\)/);
});
test('static: malformed payloads and request sizes are checked before deduplication', () => {
  const validate = section('private func validatedProductIDs', '    @MainActor\n    private func loadProducts');
  assert.match(validate, /value as\? \[String\]/);
  assert.match(validate, /ids\.count <= Self\.maximumProductIDsPerRequest/);
  assert.match(source, /maximumProductIDsPerRequest = 100/);
  assert.match(source, /maximumProductIDLength = 100/);
  assert.match(validate, /!id\.isEmpty && id\.utf8\.count <= Self\.maximumProductIDLength/);
  assert.match(validate, /id\.unicodeScalars\.allSatisfy \{ allowed\.contains\(\$0\) \}/);
  assert.match(validate, /CharacterSet\(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789\._-"\)/);
  assert.ok(validate.indexOf('ids.count <=') < validate.indexOf('return Set(ids)'));
});
test('static: purchase requires the exact queried StoreKit product and verified matching transaction', () => {
  const purchase = section('case "purchase":', 'case "restore", "sync":');
  assert.match(purchase, /validatedProductIDs\(\[productID\]\)/);
  assert.match(purchase, /products\.first\(where: \{ \$0\.id == productID \}\)/);
  assert.ok(purchase.indexOf('products.first') < purchase.indexOf('product.purchase()'));
  assert.match(purchase, /let transaction = try verified\(verification\)/);
  assert.match(purchase, /guard transaction\.productID == productID/);
  assert.match(purchase, /case \.userCancelled:/);
  assert.match(purchase, /case \.pending:/);
});
test('static: recovery and observers require verified app-scoped transactions without catalog lookup', () => {
  for (const block of [section('private func remember', '    func userContentController'),
    section('private func appendRecovery', 'private func validatedProductIDs')]) {
    assert.match(block, /guard case \.verified\(let transaction\) = result else \{ return \}/);
    assert.doesNotMatch(block, /loadProducts|requestedIDs|validatedProductIDs/);
  }
  for (const sequence of ['Transaction.updates', 'Transaction.unfinished', 'Transaction.currentEntitlements']) {
    assert.ok(source.includes(sequence));
  }
  const recovery = section('case "restore", "sync":', 'case "finish":');
  assert.match(recovery, /if operation == "sync" \{\s*try await AppStore\.sync\(\)/);
  assert.match(recovery, /recovered\.keys\.sorted\(\)/);
});
test('static: finish reserves before suspension and never trusts a cached entitlement', () => {
  const finish = section('case "finish":', '            default:');
  assert.match(finish, /!finishingTransactionIDs\.contains\(transactionID\)/);
  assert.match(finish, /!finishedTransactionIDs\.contains\(transactionID\)/);
  assert.ok(finish.indexOf('finishingTransactionIDs.insert') < finish.indexOf('for await'));
  assert.match(finish, /defer \{ finishingTransactionIDs\.remove\(transactionID\) \}/);
  assert.match(finish, /for await result in Transaction\.unfinished/);
  assert.match(finish, /guard case \.verified\(let candidate\) = result else \{ continue \}/);
  assert.match(finish, /String\(candidate\.id\) == transactionID/);
  assert.doesNotMatch(finish, /pendingTransactions\[|currentEntitlements/);
  assert.ok(finish.indexOf('guard isCurrent(context)') < finish.indexOf('await transaction.finish()'));
  assert.ok(finish.indexOf('await transaction.finish()') < finish.indexOf('finishedTransactionIDs.insert'));
  assert.match(finish, /NOT native proof of backend approval/);
});
test('static: native origin checks retain the exact HTTPS Reader main frame and port', () => {
  const handler = section('func userContentController', 'private func handle');
  assert.match(handler, /message\.frameInfo\.isMainFrame/);
  assert.match(handler, /securityOrigin\.protocol == "https"/);
  assert.match(handler, /securityOrigin\.host == "reader\.diasfitness\.com"/);
  assert.match(handler, /\[0, 443\]\.contains\(message\.frameInfo\.securityOrigin\.port\)/);
  assert.match(handler, /isReaderURL\(message\.webView\?\.url\)/);
});
