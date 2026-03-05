import Flutter
import UIKit
import CoreBluetooth
import SwiftUI
import Translation

@main
@objc class AppDelegate: FlutterAppDelegate {

    // MARK: – BLE Peripheral state
    private var peripheralManager: CBPeripheralManager?
    private var alertChunks: [[UInt8]] = []
    private var pendingChunkIndex = [UUID: Int]()  // indexed by CBCentral.identifier

    // Retained mutable characteristics so we can respond to requests
    private var alertChar:   CBMutableCharacteristic?
    private var controlChar: CBMutableCharacteristic?

    private let serviceUUID    = CBUUID(string: "0000BCBC-0000-1000-8000-00805F9B34FB")
    private let alertCharUUID  = CBUUID(string: "0000BCB1-0000-1000-8000-00805F9B34FB")
    private let controlCharUUID = CBUUID(string: "0000BCB2-0000-1000-8000-00805F9B34FB")

    private let payloadSize = 508  // 512 MTU - 4 header bytes

    // Retains the hidden SwiftUI hosting controller used for translation
    private var _translationHC: UIHostingController<AnyView>?

    // MARK: – AppDelegate lifecycle

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)

        guard let controller = window?.rootViewController as? FlutterViewController else {
            return super.application(application, didFinishLaunchingWithOptions: launchOptions)
        }

        // MARK: BLE channel
        let bleChannel = FlutterMethodChannel(
            name: "com.beconnect.beconnect/ble",
            binaryMessenger: controller.binaryMessenger
        )

        bleChannel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else { return }
            switch call.method {
            case "startAdvertising":
                guard let args      = call.arguments as? [String: Any],
                      let typedData = args["alertBytes"] as? FlutterStandardTypedData,
                      let sevInt    = args["severityByte"] as? Int else {
                    result(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
                    return
                }
                self.startGateway(alertBytes: [UInt8](typedData.data), severityByte: UInt8(sevInt))
                result(nil)
            case "stopAdvertising":
                self.stopGateway()
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        // MARK: Translation channel
        let translationChannel = FlutterMethodChannel(
            name: "com.beconnect.beconnect/translation",
            binaryMessenger: controller.binaryMessenger
        )

        translationChannel.setMethodCallHandler { [weak self] call, result in
            switch call.method {
            case "translate":
                guard let args = call.arguments as? [String: Any],
                      let text = args["text"] as? String,
                      let targetLanguage = args["targetLanguage"] as? String else {
                    result(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
                    return
                }
                if #available(iOS 18.0, *) {
                    self?.performTranslation(text: text, targetLanguage: targetLanguage, result: result)
                } else {
                    result(FlutterError(code: "UNSUPPORTED",
                                        message: "Translation requires iOS 18.0+",
                                        details: nil))
                }

            case "getDownloadedLanguages":
                if #available(iOS 18.0, *) {
                    Task {
                        let codes = await self?.downloadedLanguageCodes() ?? []
                        DispatchQueue.main.async { result(codes) }
                    }
                } else {
                    result([String]())
                }

            default:
                result(FlutterMethodNotImplemented)
            }
        }

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    // MARK: – Translation (iOS 18.0+)

    @available(iOS 18.0, *)
    private func downloadedLanguageCodes() async -> [String] {
        let candidates = ["es", "fr", "de", "zh", "ja", "ko", "pt", "ar",
                          "ru", "vi", "it", "nl", "tr", "uk", "id", "pl"]
        let availability = LanguageAvailability()
        let english = Locale.Language(identifier: "en")
        var installed: [String] = []
        for code in candidates {
            let target = Locale.Language(identifier: code)
            let status = await availability.status(from: english, to: target)
            if status == .installed {
                installed.append(code)
            }
        }
        return installed
    }

    @available(iOS 18.0, *)
    private func performTranslation(text: String, targetLanguage: String, result: @escaping FlutterResult) {
        let config = TranslationSession.Configuration(
            source: Locale.Language(identifier: "en"),
            target: Locale.Language(identifier: targetLanguage)
        )

        // The Translation framework requires a SwiftUI view with .translationTask
        // to obtain a TranslationSession. We host a hidden 0×0 view briefly.
        let view = _TranslationHelperView(text: text, configuration: config) { [weak self] outcome in
            DispatchQueue.main.async {
                self?._translationHC?.view.removeFromSuperview()
                self?._translationHC = nil
                switch outcome {
                case .success(let translated):
                    result(translated)
                case .failure(let error):
                    result(FlutterError(code: "TRANSLATION_ERROR",
                                        message: error.localizedDescription,
                                        details: nil))
                }
            }
        }

        let hc = UIHostingController(rootView: AnyView(view))
        _translationHC = hc
        hc.view.frame = .zero
        hc.view.alpha = 0
        window?.addSubview(hc.view)
    }

    // MARK: – Gateway start / stop

    private func startGateway(alertBytes: [UInt8], severityByte: UInt8) {
        let total = Int(ceil(Double(alertBytes.count) / Double(payloadSize)))

        alertChunks = (0 ..< max(total, 1)).map { i in
            let start = i * payloadSize
            let end   = min(start + payloadSize, alertBytes.count)
            let payload = Array(alertBytes[start ..< end])
            var frame: [UInt8] = [
                UInt8((i >> 8) & 0xFF), UInt8(i & 0xFF),
                UInt8((total >> 8) & 0xFF), UInt8(total & 0xFF)
            ]
            frame.append(contentsOf: payload)
            return frame
        }

        pendingChunkIndex = [:]
        peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
        // Advertising is started in peripheralManagerDidUpdateState(_:) once powered on
    }

    private func stopGateway() {
        peripheralManager?.stopAdvertising()
        peripheralManager?.removeAllServices()
        peripheralManager = nil
        alertChunks = []
        pendingChunkIndex = [:]
        alertChar   = nil
        controlChar = nil
    }
}

// MARK: – CBPeripheralManagerDelegate

extension AppDelegate: CBPeripheralManagerDelegate {

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else { return }

        let ac = CBMutableCharacteristic(
            type:        alertCharUUID,
            properties:  [.read],
            value:       nil,
            permissions: [.readable]
        )
        let cc = CBMutableCharacteristic(
            type:        controlCharUUID,
            properties:  [.write],
            value:       nil,
            permissions: [.writeable]
        )
        alertChar   = ac
        controlChar = cc

        let service = CBMutableService(type: serviceUUID, primary: true)
        service.characteristics = [ac, cc]
        peripheral.add(service)

        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
            CBAdvertisementDataLocalNameKey:    "BeConnect"
        ])
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            if request.characteristic.uuid == controlCharUUID,
               let data = request.value, data.count >= 2 {
                let idx = (Int(data[0]) << 8) | Int(data[1])
                pendingChunkIndex[request.central.identifier] = idx
                peripheral.respond(to: request, withResult: .success)
            } else {
                peripheral.respond(to: request, withResult: .requestNotSupported)
            }
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == alertCharUUID else {
            peripheral.respond(to: request, withResult: .requestNotSupported)
            return
        }

        let idx = pendingChunkIndex[request.central.identifier] ?? 0
        guard idx >= 0 && idx < alertChunks.count else {
            peripheral.respond(to: request, withResult: .readNotPermitted)
            return
        }

        let frame = Data(alertChunks[idx])
        guard request.offset <= frame.count else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = frame.subdata(in: request.offset ..< frame.count)
        peripheral.respond(to: request, withResult: .success)
    }
}

// MARK: – SwiftUI helper for Translation framework (iOS 18.0+)

@available(iOS 18.0, *)
private struct _TranslationHelperView: View {
    let text: String
    let configuration: TranslationSession.Configuration
    let completion: (Result<String, Error>) -> Void

    @State private var done = false

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .translationTask(configuration) { session in
                guard !done else { return }
                done = true
                do {
                    let response = try await session.translate(text)
                    completion(.success(response.targetText))
                } catch {
                    completion(.failure(error))
                }
            }
    }
}
