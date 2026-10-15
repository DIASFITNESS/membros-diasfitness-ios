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

    init(webViewProvider: @escaping () -> WKWebView?) {
        self.webViewProvider = webViewProvider
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "diasIAP",
              message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.host == "reader.diasfitness.com",
              let body = message.body as? [String: Any],
              let requestID = body["id"] as? String,
              let operation = body["op"] as? String else {
            return
        }

        let payload = body["payload"] as? [String: Any] ?? [:]
        Task { @MainActor in
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
                var entitlements: [[String: Any]] = []
                for await result in Transaction.currentEntitlements {
                    guard case .verified(let transaction) = result,
                          productIDs.contains(transaction.productID) else {
                        continue
                    }
                    let transactionID = String(transaction.id)
                    pendingTransactions[transactionID] = transaction
                    entitlements.append([
                        "signedTransaction": result.jwsRepresentation,
                        "transactionId": transactionID,
                        "originalTransactionId": String(transaction.originalID)
                    ])
                }
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
              let resultData = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]),
              let resultJSON = String(data: resultData, encoding: .utf8),
              let idData = try? JSONSerialization.data(withJSONObject: requestID, options: [.fragmentsAllowed]),
              let idJSON = String(data: idData, encoding: .utf8) else {
            return
        }

        webView.evaluateJavaScript("window.__diasIAPResolve && window.__diasIAPResolve(\(idJSON), \(resultJSON));", completionHandler: nil)
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
