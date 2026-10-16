# Reader native build 1 (4): validation notes

## Firebase

Push subscriptions, tokens and notification delivery already depend on Firebase Messaging. The checked-in GoogleService-Info.plist identifies com.microsoft.pwabuilder-ios and has a placeholder sender ID. Do not initialize that project for the Reader. Startup configures Firebase only when the plist bundle matches the running app and the sender ID is nonempty/nonzero; Messaging entry points require a configured Firebase app. Push remains unavailable with the current template. Obtain the correct Reader Firebase configuration through the existing secure configuration process; no credentials or Firebase project configuration were changed here.

## StoreKit contract and recovery

Existing requests remain `{id, op, payload}` through `diasIAP`. Existing replies remain `window.__diasIAPResolve(id, {ok, data/error})`. Product IDs and purchase/cancellation/error payloads are unchanged. No new callback or unsolicited response was introduced.

The observer records verified Reader transactions from Transaction.updates, including later approvals. Transaction.unfinished is read at bridge startup and on restore/sync, so recovery does not rely on memory surviving a restart. Restore/sync return the existing `data.entitlements` array, now merging current entitlements and unfinished transactions by transaction ID. Entries keep signedTransaction, transactionId and originalTransactionId. Unverified and unrelated products are excluded. There is one entry per ID per recovery response; concurrent repeated request IDs and concurrent finish calls for the same transaction are suppressed/rejected. Completed request IDs may be reused; recovery across requests intentionally remains retryable. Backend provisioning must be idempotent by transaction ID.

No transaction is automatically finished. Only the explicit finish operation calls Transaction.finish(). The frontend remains responsible for submitting the JWS to the backend, waiting for validated access provisioning, and only then sending finish. Native code does not independently prove backend approval.

Limitation: without a frontend request, late approvals are not delivered immediately. The smallest compatible web change, if absent today, is to call the existing restore operation on launch/resume and when revisiting a pending purchase; process each returned JWS through the same backend-validation flow. No frontend implementation is present in this repository, so its actual handling of recovered entries remains unverified. Do not invent an event callback or automatically finish to bypass this limitation.

## Security

Native IAP and push handlers require the main frame and HTTPS Reader origin (default port or 443). Navigation uses exact URL validation rather than substring matching or the previous unrestricted redirect bypass. Deep links and shortcuts validate the target and JSON-serialize it before JavaScript evaluation. IAP callbacks check the current native URL and recheck the origin inside JavaScript to reject a navigation race to another origin.

## Required Apple-runner checks

Linux static parsing is not an Xcode build or a StoreKit/Firebase integration test. Before distribution, compile with the existing Codemagic workflow, verify the exported IPA identifies com.diasfitness.reader version 1 build 4, and confirm build 4 is unused in App Store Connect. Validate launch with the template Firebase plist (no initialization crash), then push with valid Reader configuration when available. Test purchase, cancellation, pending approval, app restart before finish, restore/sync deduplication, backend retry/idempotence, explicit finish, deep links and rejection of foreign/HTTP origins on iOS 15+.

Codemagic authentication, signing, internal tester access and Apple processing remain external checks. Upload configuration is preserved; automatic beta review and App Store submission are both disabled, with manual release. No build, upload or publication was executed during this change.
