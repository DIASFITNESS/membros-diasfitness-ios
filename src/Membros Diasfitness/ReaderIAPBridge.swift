import Foundation
import StoreKit
import WebKit
import os

/// Native StoreKit 2 bridge for the Reader web app only.
final class ReaderIAPBridge: NSObject, WKScriptMessageHandler {
    private let webViewProvider: () -> WKWebView?
    // Per-request resource limits, not a catalog or a product authorization policy.
    private static let maximumProductIDsPerRequest = 100
    private static let maximumProductIDLength = 100

    private var pendingTransactions: [String: Transaction] = [:]

    // A navigation invalidates delivery even when the next page has the same origin.
    private var documentGeneration = UUID()
    private let callbackLogger = Logger(subsystem: "com.diasfitness.reader", category: "IAPCallback")

    private struct CallbackContext {
        weak var webView: WKWebView?
        let generation: UUID
        let documentToken: String
    }

    private enum DeliveryFailure: String {
        case documentChanged = "document_changed"
        case contextEvaluationFailed = "context_evaluation_failed"
        case contextUnavailable = "context_unavailable"
        case serializationFailed = "serialization_failed"
        case evaluationFailed = "evaluation_failed"
        case originRejected = "origin_rejected"
        case resolverUnavailable = "resolver_unavailable"
        case resolverThrew = "resolver_threw"
        case acknowledgementMissing = "acknowledgement_missing"
    }

    private var updatesTask: Task<Void, Never>?
    private var activeRequestIDs: Set<String> = []
    private var finishingTransactionIDs: Set<String> = []
    private var finishedTransactionIDs: Set<String> = []

    init(webViewProvider: @escaping () -> WKWebView?) {
        self.webViewProvider = webViewProvider
        super.init()
        updatesTask = Task { @MainActor [weak self] in
            for await result in Transaction.updates {
                guard !Task.isCancelled else { return }
                self?.remember(result)
            }
        }
        // StoreKit persists unfinished transactions across application restarts.
        Task { @MainActor [weak self] in
            for await result in Transaction.unfinished {
                self?.remember(result)
            }
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    @MainActor
    private func remember(_ result: VerificationResult<Transaction>) {
        guard case .verified(let transaction) = result else { return }
        guard !finishedTransactionIDs.contains(String(transaction.id)) else { return }
        pendingTransactions[String(transaction.id)] = transaction
        // StoreKit sequences are scoped to this app. Active products and account
        // ownership remain backend decisions, not a JS-provided recovery filter.
        // No unsolicited JS callback and, critically, no automatic finish.
        // The existing restore/sync response delivers recovered JWS payloads.
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "diasIAP",
              message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == "https",
              message.frameInfo.securityOrigin.host == "reader.diasfitness.com",
              [0, 443].contains(message.frameInfo.securityOrigin.port),
              isReaderURL(message.webView?.url),
              let body = message.body as? [String: Any],
              let requestID = body["id"] as? String,
              let operation = body["op"] as? String else {
            return
        }

        guard let sourceWebView = message.webView else { return }
        let generation = documentGeneration
        let payload = body["payload"] as? [String: Any] ?? [:]
        Task { @MainActor in
            guard sourceWebView === webViewProvider(),
                  generation == documentGeneration,
                  isReaderURL(sourceWebView.url) else {
                diagnose(.documentChanged)
                return
            }
            guard !activeRequestIDs.contains(requestID) else { return }
            activeRequestIDs.insert(requestID)
            defer {
                activeRequestIDs.remove(requestID)
            }
            guard let token = await captureDocumentToken(in: sourceWebView) else { return }
            let context = CallbackContext(webView: sourceWebView, generation: generation, documentToken: token)
            guard isCurrent(context) else {
                diagnose(.documentChanged)
                return
            }
            await handle(operation: operation, requestID: requestID, payload: payload, context: context)
        }
    }

    @MainActor
    private func handle(operation: String, requestID: String, payload: [String: Any], context: CallbackContext) async {
        do {
            switch operation {
            case "getProducts":
                let requestedIDs = try validatedProductIDs(payload["productIds"])
                let products = try await loadProducts(for: requestedIDs)
                let items = products
                    .sorted { $0.id < $1.id }
                    .map { product in
                        [
                            "id": product.id,
                            "title": product.displayName,
                            "description": product.description,
                            "displayPrice": product.displayPrice
                        ]
                    }
                await respond(requestID, context: context, success: ["products": items])

            case "purchase":
                guard let productID = payload["productId"] as? String else {
                    throw BridgeError.invalidProduct
                }
                let requestedIDs = try validatedProductIDs([productID])
                let products = try await loadProducts(for: requestedIDs)
                guard let product = products.first(where: { $0.id == productID }) else {
                    throw BridgeError.invalidProduct
                }

                guard isCurrent(context) else {
                    diagnose(.documentChanged)
                    return
                }
                let result = try await product.purchase()
                switch result {
                case .success(let verification):
                    let transaction = try verified(verification)
                    guard transaction.productID == productID else {
                        throw BridgeError.invalidProduct
                    }
                    pendingTransactions[String(transaction.id)] = transaction
                    await respond(requestID, context: context, success: [
                        "signedTransaction": verification.jwsRepresentation,
                        "transactionId": String(transaction.id)
                    ])
                case .userCancelled:
                    await respond(requestID, context: context, failure: "user_cancelled", message: "A compra foi cancelada.")
                case .pending:
                    await respond(requestID, context: context, failure: "purchase_pending", message: "A compra está pendente de aprovação.")
                @unknown default:
                    await respond(requestID, context: context, failure: "purchase_unknown", message: "Não foi possível concluir a compra.")
                }

            case "restore", "sync":
                if operation == "sync" {
                    try await AppStore.sync()
                }
                // Deduplicate by transaction ID across the two StoreKit sequences.
                // Include unfinished consumables/interrupted purchases as well as entitlements.
                var recovered: [String: [String: Any]] = [:]
                for await result in Transaction.currentEntitlements {
                    appendRecovery(result, to: &recovered)
                }
                for await result in Transaction.unfinished {
                    appendRecovery(result, to: &recovered)
                }
                let entitlements = recovered.keys.sorted().compactMap { recovered[$0] }
                await respond(requestID, context: context, success: ["entitlements": entitlements])

            case "finish":
                guard let transactionID = payload["transactionId"] as? String else {
                    throw BridgeError.transactionNotPending
                }

                // Reserve before the first suspension: another request must not
                // enumerate and finish the same transaction concurrently.
                guard !finishingTransactionIDs.contains(transactionID),
                      !finishedTransactionIDs.contains(transactionID) else {
                    throw BridgeError.transactionNotPending
                }
                finishingTransactionIDs.insert(transactionID)
                defer { finishingTransactionIDs.remove(transactionID) }

                // Memory may also contain already-finished current entitlements.
                // Always require an app-scoped, verified unfinished transaction,
                // including after restart and without a prior product lookup.
                var transaction: Transaction?
                for await result in Transaction.unfinished {
                    guard case .verified(let candidate) = result else { continue }
                    if String(candidate.id) == transactionID {
                        transaction = candidate
                        break
                    }
                }
                guard let transaction else {
                    throw BridgeError.transactionNotPending
                }
                guard isCurrent(context) else {
                    diagnose(.documentChanged)
                    return
                }

                // JS must call finish only after the Reader backend confirms
                // JWS validation and course-access provisioning. This is the
                // existing frontend contract, NOT native proof of backend approval.
                await transaction.finish()
                finishedTransactionIDs.insert(transactionID)
                pendingTransactions.removeValue(forKey: transactionID)
                await respond(requestID, context: context, success: ["finished": true])

            default:
                await respond(requestID, context: context, failure: "unsupported_operation", message: "Operação de compra não suportada.")
            }
        } catch {
            await respond(requestID, context: context, failure: "iap_error", message: error.localizedDescription)
        }
    }

    @MainActor
    private func appendRecovery(_ result: VerificationResult<Transaction>, to recovered: inout [String: [String: Any]]) {
        guard case .verified(let transaction) = result else { return }
        remember(result)
        recovered[String(transaction.id)] = [
            "signedTransaction": result.jwsRepresentation,
            "transactionId": String(transaction.id),
            "originalTransactionId": String(transaction.originalID)
        ]
    }

    private func validatedProductIDs(_ value: Any?) throws -> Set<String> {
        guard let ids = value as? [String],
              ids.count <= Self.maximumProductIDsPerRequest else {
            throw BridgeError.invalidProduct
        }
        // Apple Product IDs use ASCII letters, digits, periods, hyphens and
        // underscores, with at most 100 characters. Never trim or rewrite IDs.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        guard ids.allSatisfy({ id in
            !id.isEmpty && id.utf8.count <= Self.maximumProductIDLength
                && id.unicodeScalars.allSatisfy { allowed.contains($0) }
        }) else {
            throw BridgeError.invalidProduct
        }
        return Set(ids)
    }

    @MainActor
    private func loadProducts(for requestedIDs: Set<String>) async throws -> [Product] {
        guard !requestedIDs.isEmpty else { return [] }
        // Results are local to this request: overlapping lookups cannot overwrite
        // each other's cache. StoreKit decides availability; the backend decides
        // active catalog membership, transaction ownership and course access.
        let products = try await Product.products(for: requestedIDs.sorted())
        return products.filter { requestedIDs.contains($0.id) }
    }

    private func verified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value):
            return value
        case .unverified:
            throw BridgeError.unverifiedTransaction
        }
    }

    // Called for provisional navigation and web-process termination. Never finishes
    // or removes a StoreKit transaction; restore/sync remain the recovery path.
    @MainActor
    func documentWillChange(in webView: WKWebView) {
        guard webView === webViewProvider() else { return }
        documentGeneration = UUID()
    }

    @MainActor
    private func isCurrent(_ context: CallbackContext) -> Bool {
        guard let webView = context.webView else { return false }
        return webView === webViewProvider()
            && context.generation == documentGeneration
            && isReaderURL(webView.url)
    }

    @MainActor
    private func captureDocumentToken(in webView: WKWebView) async -> String? {
        // An immutable marker on the Document also closes the race between the
        // native URL/generation check and JavaScript execution in a new document.
        let candidate = UUID().uuidString
        let script = """
        (() => {
            if (window.top !== window || window.location.origin !== 'https://reader.diasfitness.com') return null;
            if (!Object.prototype.hasOwnProperty.call(document, '__diasIAPDocumentToken')) {
                Object.defineProperty(document, '__diasIAPDocumentToken', { value: "\(candidate)" });
            }
            return document.__diasIAPDocumentToken;
        })()
        """
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { [weak self] value, error in
                if error != nil {
                    self?.diagnose(.contextEvaluationFailed)
                    continuation.resume(returning: nil)
                } else if let token = value as? String, UUID(uuidString: token) != nil {
                    continuation.resume(returning: token)
                } else {
                    self?.diagnose(.contextUnavailable)
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    @MainActor
    private func respond(_ requestID: String, context: CallbackContext, success data: [String: Any]) async {
        await sendJavaScriptCallback(requestID: requestID, context: context, result: ["ok": true, "data": data])
    }

    @MainActor
    private func respond(_ requestID: String, context: CallbackContext, failure code: String, message: String) async {
        await sendJavaScriptCallback(requestID: requestID, context: context, result: [
            "ok": false,
            "error": ["code": code, "message": message]
        ])
    }

    @MainActor
    private func sendJavaScriptCallback(requestID: String, context: CallbackContext, result: [String: Any]) async {
        guard isCurrent(context), let webView = context.webView else {
            diagnose(.documentChanged)
            return
        }
        guard let resultData = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]),
              let resultJSON = String(data: resultData, encoding: .utf8),
              let idData = try? JSONSerialization.data(withJSONObject: requestID, options: [.fragmentsAllowed]),
              let idJSON = String(data: idData, encoding: .utf8),
              let tokenData = try? JSONSerialization.data(withJSONObject: context.documentToken, options: [.fragmentsAllowed]),
              let tokenJSON = String(data: tokenData, encoding: .utf8) else {
            diagnose(.serializationFailed)
            return
        }

        let script = """
        (() => {
            if (window.top !== window || window.location.origin !== 'https://reader.diasfitness.com') return 'origin_rejected';
            if (document.__diasIAPDocumentToken !== \(tokenJSON)) return 'document_changed';
            if (typeof window.__diasIAPResolve !== 'function') return 'resolver_unavailable';
            try {
                window.__diasIAPResolve(\(idJSON), \(resultJSON));
                return 'delivered';
            } catch (_) {
                return 'resolver_threw';
            }
        })()
        """
        // One attempt only. The acknowledgement means the resolver was invoked
        // without a synchronous exception, not that the backend provisioned access.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            webView.evaluateJavaScript(script) { [weak self] value, error in
                if error != nil {
                    self?.diagnose(.evaluationFailed)
                } else if let status = value as? String, status == "delivered" {
                    // Keep the existing protocol; no backend acknowledgement is invented.
                } else if let status = value as? String, let failure = DeliveryFailure(rawValue: status) {
                    self?.diagnose(failure)
                } else {
                    self?.diagnose(.acknowledgementMissing)
                }
                continuation.resume()
            }
        }
    }

    private func diagnose(_ failure: DeliveryFailure) {
        // Only fixed codes: never interpolate JS errors, IDs, URLs or IAP payloads.
        callbackLogger.error("callback_delivery_failure reason=\(failure.rawValue, privacy: .public)")
    }

    private enum BridgeError: LocalizedError {
        case invalidProduct
        case unverifiedTransaction
        case transactionNotPending

        var errorDescription: String? {
            switch self {
            case .invalidProduct:
                return "Produto de compra não reconhecido."
            case .unverifiedTransaction:
                return "A transação não pôde ser verificada pelo StoreKit."
            case .transactionNotPending:
                return "Transação não encontrada para finalização. Valide a compra novamente antes de tentar finalizar."
            }
        }
    }
}
