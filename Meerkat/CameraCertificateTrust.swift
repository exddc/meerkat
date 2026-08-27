import AppKit
import VLCKitSPM

@MainActor
final class CameraCertificateTrust: NSObject, @MainActor VLCCustomDialogRendererProtocol {
    static let shared = CameraCertificateTrust()

    private var allowedHosts = Set<String>()
    private var redactions: [(value: String, replacement: String)] = []
    private let logger = RedactedVLCLogger()
    let library: VLCLibrary
    private var dialogProvider: VLCDialogProvider!

    private override init() {
        library = VLCLibrary(options: ["--no-drop-late-frames"])
        super.init()

#if DEBUG
        library.loggers = [logger]
#endif
        dialogProvider = VLCDialogProvider(library: library, customUI: true)
        dialogProvider.customRenderer = self
    }

    func register(_ camera: Camera) {
        if camera.streamURL.path == "/flv", let host = camera.streamURL.host {
            allowedHosts.insert(host)
        }
        for redaction in camera.logRedactions {
            guard !redactions.contains(where: { $0.value == redaction.value }) else {
                continue
            }
            redactions.append(redaction)
        }
        logger.redactions = redactions
    }

    func showError(withTitle error: String, message: String) {
        debugLog("error title=\(sanitized(error)) message=\(sanitized(message))")
    }

    func showLogin(
        withTitle title: String,
        message: String,
        defaultUsername username: String?,
        askingForStorage: Bool,
        withReference reference: NSValue
    ) {
        debugLog("unexpected login request dismissed")
        dialogProvider.dismissDialog(withReference: reference)
    }

    func showQuestion(
        withTitle title: String,
        message: String,
        type questionType: VLCDialogQuestionType,
        cancel cancelString: String?,
        action1String: String?,
        action2String: String?,
        withReference reference: NSValue
    ) {
        guard action1String != nil,
              let host = allowedHosts.first(where: message.contains) else {
            debugLog("unrecognized question dismissed")
            dialogProvider.dismissDialog(withReference: reference)
            return
        }

        debugLog("accepting temporary certificate host=\(host)")
        dialogProvider.postAction(1, forDialogReference: reference)
    }

    func showProgress(
        withTitle title: String,
        message: String,
        isIndeterminate: Bool,
        position: Float,
        cancel cancelString: String?,
        withReference reference: NSValue
    ) {}

    func updateProgress(
        withReference reference: NSValue,
        message: String?,
        position: Float
    ) {}

    func cancelDialog(withReference reference: NSValue) {
        dialogProvider.dismissDialog(withReference: reference)
    }

    private func debugLog(_ message: @autoclosure () -> String) {
#if DEBUG
        print("[Meerkat][TLS] \(message())")
#endif
    }

    private func sanitized(_ text: String) -> String {
        redactions.reduce(text) { result, redaction in
            result.replacingOccurrences(
                of: redaction.value,
                with: redaction.replacement
            )
        }
    }
}

private final class RedactedVLCLogger: NSObject, VLCLogging {
    var level = VLCLogLevel.debug
    var redactions: [(value: String, replacement: String)] = [] {
        didSet {
            expandedRedactions = redactions.flatMap { redaction in
                guard let encoded = redaction.value.addingPercentEncoding(
                    withAllowedCharacters: .alphanumerics
                ) else {
                    return [redaction]
                }

                return [redaction, (encoded, redaction.replacement)]
            }
        }
    }

    private var expandedRedactions: [(value: String, replacement: String)] = []

    func handleMessage(
        _ message: String,
        logLevel: VLCLogLevel,
        context: VLCLogContext?
    ) {
#if DEBUG
        let safeMessage = expandedRedactions.reduce(message) { result, redaction in
            result.replacingOccurrences(
                of: redaction.value,
                with: redaction.replacement
            )
        }
        let keywords: [String] = [
            "access",
            "authentication",
            "certificate",
            "clock",
            "connection",
            "http",
            "jitter",
            "PCR",
            "request",
            "response",
            "timestamp",
            "tls",
        ]
        guard keywords.contains(where: { safeMessage.localizedCaseInsensitiveContains($0) }) else {
            return
        }
        print("[Meerkat][VLC][\(context?.module ?? "unknown")] \(safeMessage)")
#endif
    }
}
