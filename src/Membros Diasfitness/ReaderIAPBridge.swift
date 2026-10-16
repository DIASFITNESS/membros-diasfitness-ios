import Foundation
import StoreKit
import WebKit

/// Native StoreKit 2 bridge for the Reader web app only.
final class ReaderIAPBridge: NSObject, WKScriptMessageHandler {
    private let webViewProvider: () -> WKWebView?
    private let productIDs: Set<String> = [
        "com.diasfitness.reader.coreografias_fitness",
        "com.diasfitness.reader.alongamento",
        "com.diasfitness.reader.avaliacao_funcional"
    ]

    private var productsByID: [String: Product] = [:]
    private var pendingTransactions: [String: Transaction] = [:]

    private var updatesTask: Task<Void, Never>?
    private var activeRequestIDs: Set<String> = []
    private var finishingTransactionIDs: Set<String> = []

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
        guard case .verified(let transaction) = result,
              productIDs.contains(transaction.productID) else { return }
        pendingTransactions[String(transaction.id)] = transaction
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

        let payload = body["payload"] as? [String: Any] ?? [:]
        Task { @MainActor in
            guard isReaderURL(webViewProvider()?.url),
                  !activeRequestIDs.contains(requestID) else { return }
            activeRequestIDs.insert(requestID)
            defer {
                activeRequestIDs.remove(requestID)
            }
            await handle(operation: operation, requestID: requestID, payload: payload)
        }
    }

    @MainActor
    private func handle(operation: String, requestID: String, payload: [String: Any]) async {
        do {
            switch operation {
            case "getProducts":
                try await loadProducts()
                let requestedIDs = Set(payload["productIds"] as? [String] ?? Array(productIDs))
                let items = productsByID.values
                    .filter { requestedIDs.contains($0.id) }
                    .sorted { $0.id < $1.id }
                    .map { product in
                        [
                            "id": product.id,
                            "title": product.displayName,
                            "description": product.description,
                            "displayPrice": product.displayPrice
                        ]
                    }
                respond(requestID, success: ["products": items])

            case "purchase":
                try await loadProducts()
                guard let productID = payload["productId"] as? String,
                      productIDs.contains(productID),
                      let product = productsByID[productID] else {
                    throw BridgeError.invalidProduct
                }

                guard isReaderURL(webViewProvider()?.url) else { return }
                let result = try await product.purchase()
                switch result {
                case .success(let verification):
                    let transaction = try verified(verification)
                    pendingTransactions[String(transaction.id)] = transaction
                    respond(requestID, success: [
                        "signedTransaction": verification.jwsRepresentation,
                        "transactionId": String(transaction.id)
                    ])
                case .userCancelled:
                    respond(requestID, failure: "user_cancelled", message: "A compra foi cancelada.")
                case .pending:
                    respond(requestID, failure: "purchase_pending", message: "A compra está pendente de aprovação.")
                @unknown default:
                    respond(requestID, failure: "purchase_unknown", message: "Não foi possível concluir a compra.")
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
                respond(requestID, success: ["entitlements": entitlements])

            case "finish":
                guard let transactionID = payload["transactionId"] as? String else {
                    throw BridgeError.transactionNotPending
                }

                // First use the in-memory transaction from the purchase flow.
                // If the WebView/app was restarted, recover only an unfinished
                // StoreKit transaction; never finish an arbitrary entitlement.
                var transaction = pendingTransactions[transactionID]
                if transaction == nil {
                    for await result in Transaction.unfinished {
                        guard case .verified(let candidate) = result else { continue }
                        if String(candidate.id) == transactionID,
                           productIDs.contains(candidate.productID) {
                            transaction = candidate
                            break
                        }
                    }
                }
                guard let transaction else {
                    throw BridgeError.transactionNotPending
                }

                guard isReaderURL(webViewProvider()?.url) else { return }
                guard !finishingTransactionIDs.contains(transactionID) else {
                    throw BridgeError.transactionNotPending
                }
                finishingTransactionIDs.insert(transactionID)
                defer { finishingTransactionIDs.remove(transactionID) }

                // JS must call finish only after the Reader backend confirms
                // JWS validation and course-access provisioning.
                await transaction.finish()
                pendingTransactions.removeValue(forKey: transactionID)
                respond(requestID, success: ["finished": true])

            default:
                respond(requestID, failure: "unsupported_operation", message: "Operação de compra não suportada.")
            }
        } catch {
            respond(requestID, failure: "iap_error", message: error.localizedDescription)
        }
    }

    @MainActor
    private func appendRecovery(_ result: VerificationResult<Transaction>, to recovered: inout [String: [String: Any]]) {
        guard case .verified(let transaction) = result,
              productIDs.contains(transaction.productID) else { return }
        remember(result)
        recovered[String(transaction.id)] = [
            "signedTransaction": result.jwsRepresentation,
            "transactionId": String(transaction.id),
            "originalTransactionId": String(transaction.originalID)
        ]
    }

    @MainActor
    private func loadProducts() async throws {
        let products = try await Product.products(for: Array(productIDs))
        productsByID = Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0) })
    }

    private func verified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value):
            return value
        case .unverified:
            throw BridgeError.unverifiedTransaction
        }
    }

    @MainActor
    private func respond(_ requestID: String, success data: [String: Any]) {
        sendJavaScriptCallback(requestID: requestID, result: ["ok": true, "data": data])
    }

    @MainActor
    private func respond(_ requestID: String, failure code: String, message: String) {
        sendJavaScriptCallback(requestID: requestID, result: [
            "ok": false,
            "error": ["code": code, "message": message]
        ])
    }

    @MainActor
    private func sendJavaScriptCallback(requestID: String, result: [String: Any]) {
        guard let webView = webViewProvider(),
              isReaderURL(webView.url),
              let resultData = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]),
              let resultJSON = String(data: resultData, encoding: .utf8),
              let idData = try? JSONSerialization.data(withJSONObject: requestID, options: [.fragmentsAllowed]),
              let idJSON = String(data: idData, encoding: .utf8) else {
            return
        }

        webView.evaluateJavaScript("if (window.top === window && window.location.origin === 'https://reader.diasfitness.com') { window.__diasIAPResolve && window.__diasIAPResolve(\(idJSON), \(resultJSON)); }", completionHandler: nil)
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
