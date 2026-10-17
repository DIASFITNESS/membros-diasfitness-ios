# Reader IAP callback correction — candidate 1 (5)

Base reviewed: `00dc8d3882c2ed3d1503303790ddef5a210cf7b4` on `main`.
This change is a review candidate, not an iOS build or a demonstrated fix for the
reported purchase-confirmation incident. No purchase or finish was executed.

## Change and delivery semantics

Previously, `evaluateJavaScript` discarded its completion result and the optional
resolver invocation silently did nothing when the resolver was unavailable.

Requests now capture the source WKWebView, a native navigation generation, and an
immutable per-Document marker before executing an operation. Navigation starts and
web-process termination invalidate the generation. A replaced WKWebView cannot
receive an old result. Immediately before invoking the resolver, JavaScript checks
both the Reader origin and the Document marker, covering replacement between the
native check and JavaScript execution. A navigation that later fails conservatively
invalidates old delivery too; recover using a new restore/sync request.

There is one delivery attempt. Fixed failure codes distinguish document changes,
missing resolvers, synchronous resolver exceptions, evaluator errors, serialization
failures and absent/unexpected acknowledgements. The OS log subsystem is
`com.diasfitness.reader`, category `IAPCallback`. Logs contain only fixed reason
codes; no request IDs, transaction IDs, JWS, receipts, URLs, exception descriptions,
tokens, email addresses or other user data are logged.

`delivered` means that `window.__diasIAPResolve(id, {ok, data/error})` was invoked
without a synchronous exception. The resolver may return undefined as before.
This is not acknowledgement that its pending-request map recognized the ID, that
an asynchronous promise succeeded, or that the backend validated/provisioned access.
The marker is internal to native delivery and adds no required web protocol field.

## Preserved transaction behavior

- Product IDs, Product.products(for:), Product.purchase(), displayPrice, monetary
  formatting and Storefront behavior are unchanged.
- Verified purchase success still supplies signedTransaction and string transactionId.
- Local StoreKit cryptographic verification is unchanged.
- Observer, unfinished recovery, entitlement merge/deduplication and JWS recovery
  fields remain unchanged. A lost callback never removes a pending transaction.
- No callback failure retries purchase or finish. No unsolicited delivery to a new
  document is introduced. Recovery requires a newly correlated restore/sync request.
- The only Transaction.finish() remains in the explicit finish operation. Native
  code still trusts the frontend to call finish only after backend validation and
  course provisioning; this change cannot independently prove that ordering.

## Executed checks in the Linux environment

Run `node tests/reader-iap-callback.test.cjs` (Node standard library only).
The suite extracts and executes the actual JavaScript from the Swift source:
normal delivery, absent/non-function resolver, resolver exception, evaluator-level
exception, same-origin document replacement, a new correlated recovery response,
foreign origin/frame rejection, concurrent stable markers, JSON-special IDs and
undefined resolver returns. Three additional checks are explicitly static: native
error/acknowledgement handling and safe logging, navigation/view guards, and
unchanged recovery/verification blocks plus explicit-only finish. Baseline SHA-256
values are taken from the audited base commit.

Result: 13/13 passed. The document-loss scenario uses simulated documents and
synthetic transaction data; it does not execute a StoreKit purchase. The evaluator
exception test uses Node's VM, not WKWebView's NSError completion.

Tree-sitter Swift 0.7.4 with tree-sitter 0.26.0 parsed ReaderIAPBridge.swift and
ViewController.swift without syntax errors. This is syntax parsing only, not Swift
type checking, linking, Xcode compilation or runtime validation. Swift, swiftc,
xcodebuild and the Apple SDK are unavailable here. `git diff --check` also passed.

## Required frontend confirmation

No Lovable/frontend implementation is present in this repository. The call shape,
fields and cancellation/error codes are unchanged, but deployed compatibility has
not been exercised. Confirm that the frontend:

1. Installs the resolver and registers each pending ID before posting its request.
2. Reads data.signedTransaction and data.transactionId, and handles data.entitlements
   from restore/sync through the same backend verification/provisioning flow.
3. Uses fresh IDs after document recreation and invokes restore on launch/resume or
   revisiting an interrupted purchase, if it does not already do so.
4. Treats a web timeout as an interrupted confirmation, not authority to repurchase
   or finish; applies backend idempotence by transaction ID.
5. Calls finish only after confirmed backend validation and access provisioning.

These are complementary checks, not implemented frontend/backend changes. A
same-document app reset or resolver that silently ignores an unknown ID cannot be
confirmed as consumed without a future explicit frontend acknowledgement contract.

## Apple-runner checklist — not executed

After approval, use an Apple runner to compile/type-check with the supported Xcode
and dependencies. No successful iOS compilation is claimed in this review.
On an authorized simulator/device test setup, validate normal callback, missing
resolver, resolver exception, actual evaluateJavaScript error/process termination,
reload/deep link/replacement during an outstanding operation, concurrent requests,
restoration after restart, and backend retry/idempotence. Confirm no automatic
finish and check actual frontend/backend ordering before explicit finish. Sandbox
purchase/finish actions require separate test authorization; none were run here.

## Plan for Codemagic 1 (5) — no workflow run started

1. Review this branch and approve merge separately. Confirm build number 5 is unused
   in App Store Connect. Debug and Release now both declare CURRENT_PROJECT_VERSION
   5; MARKETING_VERSION remains 1 and bundle ID remains com.diasfitness.reader.
2. After explicit authorization to generate a build, select the approved commit in
   the existing `ios-members` workflow and record its SHA. Do not run an old main
   revision. Existing Codemagic credentials/signing remain unchanged.
3. Run the existing dependency/signing/IPA workflow. Inspect compilation warnings,
   archive/export logs and exported Info.plist: com.diasfitness.reader, version 1,
   build 5. Do not distribute an artifact that fails these checks.
4. Keep automatic TestFlight and App Store submission disabled. codemagic.yaml is
   unchanged and already sets both submit_to_testflight and submit_to_app_store to
   false. Verify dashboard triggers separately before starting any run.
5. Keep the artifact for review. Upload/publication and Apple submission require
   the user's separate approval. No IPA has been generated, uploaded or submitted.
