import UIKit
import WebKit
import AuthenticationServices
import SafariServices
import PhotosUI
import UniformTypeIdentifiers
import ObjectiveC

// MARK: - File Upload Coordinator

private var fileUploadCoordinatorKey: UInt8 = 0

private final class FileUploadCoordinator: NSObject, PHPickerViewControllerDelegate, UIDocumentPickerDelegate {
    private let completionHandler: ([URL]?) -> Void
    private weak var presenter: UIViewController?

    init(
        presenter: UIViewController,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        self.presenter = presenter
        self.completionHandler = completionHandler
        super.init()
    }

    // MARK: Source Selection

    func presentSourceChooser() {
        guard let presenter = presenter else {
            completionHandler(nil)
            return
        }

        let alert = UIAlertController(
            title: "Selecionar foto",
            message: "Escolha de onde deseja selecionar a imagem.",
            preferredStyle: .actionSheet
        )

        alert.addAction(
            UIAlertAction(
                title: "Biblioteca de Fotos",
                style: .default
            ) { [weak self] _ in
                self?.presentPhotoPicker()
            }
        )

        alert.addAction(
            UIAlertAction(
                title: "Escolher Arquivo",
                style: .default
            ) { [weak self] _ in
                self?.presentDocumentPicker()
            }
        )

        alert.addAction(
            UIAlertAction(
                title: "Cancelar",
                style: .cancel
            ) { [weak self] _ in
                self?.completionHandler(nil)
            }
        )

        // Necessário para apresentação correta em iPad.
        if let popover = alert.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(
                x: presenter.view.bounds.midX,
                y: presenter.view.bounds.midY,
                width: 0,
                height: 0
            )
            popover.permittedArrowDirections = []
        }

        presenter.present(alert, animated: true)
    }

    // MARK: Photo Library

    private func presentPhotoPicker() {
        guard let presenter = presenter else {
            completionHandler(nil)
            return
        }

        if #available(iOS 14.0, *) {
            var configuration = PHPickerConfiguration()
            configuration.filter = .images
            configuration.selectionLimit = 1

            let picker = PHPickerViewController(
                configuration: configuration
            )

            picker.delegate = self

            presenter.present(
                picker,
                animated: true
            )
        } else {
            // Fallback para versões antigas do iOS.
            let picker = UIDocumentPickerViewController(
                documentTypes: ["public.image"],
                in: .import
            )

            picker.delegate = self
            picker.allowsMultipleSelection = false

            presenter.present(
                picker,
                animated: true
            )
        }
    }

    // MARK: Document Picker

    private func presentDocumentPicker() {
        guard let presenter = presenter else {
            completionHandler(nil)
            return
        }

        if #available(iOS 14.0, *) {
            let picker = UIDocumentPickerViewController(
                forOpeningContentTypes: [.image],
                asCopy: true
            )

            picker.delegate = self
            picker.allowsMultipleSelection = false

            presenter.present(
                picker,
                animated: true
            )
        } else {
            let picker = UIDocumentPickerViewController(
                documentTypes: ["public.image"],
                in: .import
            )

            picker.delegate = self
            picker.allowsMultipleSelection = false

            presenter.present(
                picker,
                animated: true
            )
        }
    }

    // MARK: PHPickerViewControllerDelegate

    @available(iOS 14.0, *)
    func picker(
        _ picker: PHPickerViewController,
        didFinishPicking results: [PHPickerResult]
    ) {
        picker.dismiss(animated: true)

        guard let result = results.first else {
            completionHandler(nil)
            return
        }

        let provider = result.itemProvider

        let imageTypeIdentifier =
            provider.registeredTypeIdentifiers.first {
                UTType($0)?.conforms(to: .image) == true
            }
            ?? UTType.image.identifier

        provider.loadFileRepresentation(
            forTypeIdentifier: imageTypeIdentifier
        ) { [weak self] temporaryURL, error in

            guard let self = self else {
                return
            }

            guard
                let temporaryURL = temporaryURL,
                error == nil
            else {
                DispatchQueue.main.async {
                    self.completionHandler(nil)
                }
                return
            }

            let type = UTType(imageTypeIdentifier)

            let fileExtension: String = {
                if let preferredExtension = type?.preferredFilenameExtension,
                   !preferredExtension.isEmpty {
                    return preferredExtension
                }

                let fallbackExtension = temporaryURL.pathExtension

                return fallbackExtension.isEmpty
                    ? "jpg"
                    : fallbackExtension
            }()

            let destinationURL =
                FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "diasfitness-profile-\(UUID().uuidString)"
                    )
                    .appendingPathExtension(fileExtension)

            do {
                if FileManager.default.fileExists(
                    atPath: destinationURL.path
                ) {
                    try FileManager.default.removeItem(
                        at: destinationURL
                    )
                }

                try FileManager.default.copyItem(
                    at: temporaryURL,
                    to: destinationURL
                )

                DispatchQueue.main.async {
                    self.completionHandler([destinationURL])
                }

            } catch {
                DispatchQueue.main.async {
                    self.completionHandler(nil)
                }
            }
        }
    }

    // MARK: UIDocumentPickerDelegate

    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        guard let sourceURL = urls.first else {
            completionHandler(nil)
            return
        }

        let didStartAccessing =
            sourceURL.startAccessingSecurityScopedResource()

        defer {
            if didStartAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let destinationURL =
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "diasfitness-profile-\(UUID().uuidString)"
                )
                .appendingPathExtension(
                    sourceURL.pathExtension.isEmpty
                    ? "jpg"
                    : sourceURL.pathExtension
                )

        do {
            if FileManager.default.fileExists(
                atPath: destinationURL.path
            ) {
                try FileManager.default.removeItem(
                    at: destinationURL
                )
            }

            try FileManager.default.copyItem(
                at: sourceURL,
                to: destinationURL
            )

            completionHandler([destinationURL])

        } catch {
            completionHandler(nil)
        }
    }

    func documentPickerWasCancelled(
        _ controller: UIDocumentPickerViewController
    ) {
        completionHandler(nil)
    }
}


// MARK: - WebView Creation

func createWebView(
    container: UIView,
    WKSMH: WKScriptMessageHandler,
    WKND: WKNavigationDelegate,
    NSO: NSObject,
    VC: ViewController
) -> WKWebView {

    let config = WKWebViewConfiguration()
    let userContentController = WKUserContentController()

    userContentController.add(
        WKSMH,
        name: "print"
    )

    userContentController.add(
        WKSMH,
        name: "push-subscribe"
    )

    userContentController.add(
        WKSMH,
        name: "push-permission-request"
    )

    userContentController.add(
        WKSMH,
        name: "push-permission-state"
    )

    userContentController.add(
        WKSMH,
        name: "push-token"
    )

    config.userContentController = userContentController

    config.limitsNavigationsToAppBoundDomains = true
    config.allowsInlineMediaPlayback = true
    config.preferences.javaScriptCanOpenWindowsAutomatically = true

    config.preferences.setValue(
        true,
        forKey: "standalone"
    )

    let webView = WKWebView(
        frame: calcWebviewFrame(
            webviewView: container,
            toolbarView: nil
        ),
        configuration: config
    )

    setCustomCookie(
        webView: webView
    )

    webView.autoresizingMask = [
        .flexibleWidth,
        .flexibleHeight
    ]

    webView.isHidden = true

    webView.navigationDelegate = WKND

    // IMPORTANTE:
    // O WKUIDelegate controla os painéis nativos,
    // incluindo o painel de upload de arquivos.
    webView.uiDelegate = VC

    webView.scrollView.bounces = false
    webView.scrollView.contentInsetAdjustmentBehavior = .never
    webView.allowsBackForwardNavigationGestures = true

    // Check if macCatalyst 16.4+ is available and if so,
    // enable web inspector.
    // Supported on iOS 16.4+ and macOS 13.3+.
    if #available(iOS 16.4, macOS 13.3, *) {
        webView.isInspectable = true
    }

    let deviceModel = UIDevice.current.model
    let osVersion = UIDevice.current.systemVersion

    webView.configuration.applicationNameForUserAgent =
        "Safari/604.1"

    webView.customUserAgent =
        "Mozilla/5.0 (\(deviceModel); CPU \(deviceModel) OS " +
        "\(osVersion.replacingOccurrences(of: ".", with: "_")) " +
        "like Mac OS X) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/\(osVersion) " +
        "Mobile/15E148 Safari/604.1 PWAShell"

    webView.addObserver(
        NSO,
        forKeyPath: #keyPath(WKWebView.estimatedProgress),
        options: NSKeyValueObservingOptions.new,
        context: nil
    )

    #if DEBUG
    if #available(iOS 16.4, *) {
        webView.isInspectable = true
    }
    #endif

    return webView
}


// MARK: - App Store Referrer

func setAppStoreAsReferrer(
    contentController: WKUserContentController
) {
    let scriptSource =
        "document.referrer = `app-info://platform/ios-store`;"

    let script = WKUserScript(
        source: scriptSource,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true
    )

    contentController.addUserScript(script)
}


// MARK: - Custom Cookie

func setCustomCookie(
    webView: WKWebView
) {
    let _platformCookie = HTTPCookie(
        properties: [
            .domain: rootUrl.host!,
            .path: "/",
            .name: platformCookie.name,
            .value: platformCookie.value,
            .secure: "FALSE",
            .expires: NSDate(
                timeIntervalSinceNow: 31556926
            )
        ]
    )!

    webView.configuration
        .websiteDataStore
        .httpCookieStore
        .setCookie(_platformCookie)
}


// MARK: - WebView Frame

func calcWebviewFrame(
    webviewView: UIView,
    toolbarView: UIToolbar?
) -> CGRect {

    if ((toolbarView) != nil) {

        return CGRect(
            x: 0,
            y: toolbarView!.frame.height,
            width: webviewView.frame.width,
            height: webviewView.frame.height
                - toolbarView!.frame.height
        )

    } else {

        let winScene =
            UIApplication.shared.connectedScenes.first

        let windowScene =
            winScene as! UIWindowScene

        var statusBarHeight =
            windowScene.statusBarManager?
                .statusBarFrame.height ?? 0

        switch displayMode {

        case "fullscreen":

            #if targetEnvironment(macCatalyst)

            if let titlebar = windowScene.titlebar {
                titlebar.titleVisibility = .hidden
                titlebar.toolbar = nil
            }

            #endif

            return CGRect(
                x: 0,
                y: 0,
                width: webviewView.frame.width,
                height: webviewView.frame.height
            )

        default:

            #if targetEnvironment(macCatalyst)

            statusBarHeight = 29

            #endif

            let windowHeight =
                webviewView.frame.height
                - statusBarHeight

            return CGRect(
                x: 0,
                y: statusBarHeight,
                width: webviewView.frame.width,
                height: windowHeight
            )
        }
    }
}


// MARK: - WKUIDelegate / WKDownloadDelegate

extension ViewController: WKUIDelegate, WKDownloadDelegate {

    // MARK: New Tabs

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {

        if navigationAction.targetFrame == nil {
            webView.load(
                navigationAction.request
            )
        }

        return nil
    }


    // MARK: File Upload

    // Esta API de customização do upload foi introduzida no iOS 18.4.
    // Em versões anteriores, o WKWebView usa o comportamento
    // padrão de upload do Safari.
    @available(iOS 18.4, *)
    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {

        // O arquivo pode solicitar múltipla seleção,
        // mas para a foto de perfil usamos uma única imagem.
        let coordinator = FileUploadCoordinator(
            presenter: self
        ) { [weak webView] urls in

            completionHandler(urls)

            // Libera o coordinator depois que o upload
            // foi entregue ao WebKit.
            if let webView = webView {

                objc_setAssociatedObject(
                    webView,
                    &fileUploadCoordinatorKey,
                    nil,
                    .OBJC_ASSOCIATION_RETAIN_NONATOMIC
                )
            }
        }

        // Mantém o coordinator vivo durante toda a seleção.
        objc_setAssociatedObject(
            webView,
            &fileUploadCoordinatorKey,
            coordinator,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )

        coordinator.presentSourceChooser()
    }


    // MARK: Navigation Policy

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (
            WKNavigationActionPolicy
        ) -> Void
    ) {

        if navigationAction.request.url?.scheme == "about" {
            return decisionHandler(.allow)
        }

        if navigationAction.shouldPerformDownload
            || navigationAction.request.url?.scheme == "blob" {

            return decisionHandler(.download)
        }

        if let requestUrl = navigationAction.request.url {

            // Schemes that should always be handed off
            // to the system / other apps.
            let externalSchemes = [
                "tel",
                "telprompt",
                "mailto",
                "facetime",
                "facetime-audio",
                "fb",
                "fb-messenger",
                "sms",
                "itms-services",
                "itms-apps",
                "itms",
                "maps"
            ]

            if let requestScheme =
                requestUrl.scheme?.lowercased(),
               externalSchemes.contains(requestScheme) {

                decisionHandler(.cancel)

                if UIApplication.shared.canOpenURL(
                    requestUrl
                ) {
                    UIApplication.shared.open(
                        requestUrl
                    )
                }

                return
            }

            if let requestHost = requestUrl.host {

                // Match auth origin first because host origin
                // may be a subset of auth origin.
                let matchingAuthOrigin =
                    authOrigins.first {
                        requestHost.range(of: $0) != nil
                    }

                if matchingAuthOrigin != nil {

                    decisionHandler(.allow)

                    if toolbarView.isHidden {

                        toolbarView.isHidden = false

                        webView.frame =
                            calcWebviewFrame(
                                webviewView: webviewView,
                                toolbarView: toolbarView
                            )
                    }

                    return
                }

                let matchingHostOrigin =
                    allowedOrigins.first {
                        requestHost.range(of: $0) != nil
                    }

                if matchingHostOrigin != nil {

                    decisionHandler(.allow)

                    if !toolbarView.isHidden {

                        toolbarView.isHidden = true

                        webView.frame =
                            calcWebviewFrame(
                                webviewView: webviewView,
                                toolbarView: nil
                            )
                    }

                    return
                }

                if navigationAction.navigationType == .other
                    && navigationAction.value(
                        forKey: "syntheticClickType"
                    ) as! Int == 0
                    && navigationAction.targetFrame != nil {

                    decisionHandler(.allow)
                    return

                } else {

                    decisionHandler(.cancel)
                }

                if ["http", "https"].contains(
                    requestUrl.scheme?.lowercased() ?? ""
                ) {

                    let safariViewController =
                        SFSafariViewController(
                            url: requestUrl
                        )

                    self.present(
                        safariViewController,
                        animated: true,
                        completion: nil
                    )

                } else {

                    if UIApplication.shared.canOpenURL(
                        requestUrl
                    ) {

                        UIApplication.shared.open(
                            requestUrl
                        )
                    }
                }

            } else {

                decisionHandler(.cancel)

                if requestUrl.isFileURL {

                    downloadAndOpenFile(
                        url: requestUrl.absoluteURL
                    )
                }
            }

        } else {

            decisionHandler(.cancel)
        }
    }


    // MARK: JavaScript Alert

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {

        let alert = UIAlertController(
            title: nil,
            message: message,
            preferredStyle: .alert
        )

        let okAction = UIAlertAction(
            title: "OK",
            style: .default
        ) { _ in

            completionHandler()
        }

        alert.addAction(okAction)

        present(
            alert,
            animated: true,
            completion: nil
        )
    }


    // MARK: JavaScript Confirm

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {

        let alert = UIAlertController(
            title: nil,
            message: message,
            preferredStyle: .alert
        )

        let cancelAction = UIAlertAction(
            title: "Cancel",
            style: .cancel
        ) { _ in

            completionHandler(false)
        }

        let okAction = UIAlertAction(
            title: "OK",
            style: .default
        ) { _ in

            completionHandler(true)
        }

        alert.addAction(cancelAction)
        alert.addAction(okAction)

        present(
            alert,
            animated: true,
            completion: nil
        )
    }


    // MARK: JavaScript Prompt

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {

        let alert = UIAlertController(
            title: nil,
            message: prompt,
            preferredStyle: .alert
        )

        let cancelAction = UIAlertAction(
            title: "Cancel",
            style: .cancel
        ) { _ in

            completionHandler(nil)
        }

        let okAction = UIAlertAction(
            title: "OK",
            style: .default
        ) { _ in

            if let input =
                alert.textFields?.first?.text {

                completionHandler(input)

            } else {

                completionHandler(nil)
            }
        }

        alert.addTextField { textField in
            textField.placeholder = defaultText
        }

        alert.addAction(cancelAction)
        alert.addAction(okAction)

        present(
            alert,
            animated: true,
            completion: nil
        )
    }


    // MARK: Download and Open File

    func downloadAndOpenFile(
        url: URL
    ) {

        let destinationFileUrl = url

        let sessionConfig =
            URLSessionConfiguration.default

        let session =
            URLSession(
                configuration: sessionConfig
            )

        let request =
            URLRequest(
                url: url
            )

        let task =
            session.downloadTask(
                with: request
            ) { (
                tempLocalUrl,
                response,
                error
            ) in

                if let tempLocalUrl = tempLocalUrl,
                   error == nil {

                    if let statusCode =
                        (response as? HTTPURLResponse)?.statusCode {

                        print(
                            "Successfully download. Status code: \(statusCode)"
                        )
                    }

                    do {

                        try FileManager.default.copyItem(
                            at: tempLocalUrl,
                            to: destinationFileUrl
                        )

                        self.openFile(
                            url: destinationFileUrl
                        )

                    } catch let writeError {

                        print(
                            "Error creating a file \(destinationFileUrl): \(writeError)"
                        )
                    }

                } else {

                    print(
                        "Error took place while downloading a file. " +
                        "Error description: " +
                        "\(error?.localizedDescription ?? "N/A")"
                    )
                }
            }

        task.resume()
    }


    // MARK: Open File

    func openFile(
        url: URL
    ) {

        self.documentController =
            UIDocumentInteractionController(
                url: url
            )

        self.documentController?.delegate = self

        self.documentController?.presentPreview(
            animated: true
        )
    }


    // MARK: WKDownloadDelegate

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {

        download.delegate = self
    }


    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {

        let documentsPath =
            FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0]

        let fileURL =
            documentsPath.appendingPathComponent(
                suggestedFilename
            )

        // Remove existing file if it exists,
        // otherwise it may show old content.
        if FileManager.default.fileExists(
            atPath: fileURL.path
        ) {

            try? FileManager.default.removeItem(
                at: fileURL
            )
        }

        self.openFile(
            url: fileURL
        )

        completionHandler(fileURL)
    }
}
