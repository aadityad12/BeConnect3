import Flutter
import UIKit
import CoreBluetooth

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

    // MARK: – AppDelegate lifecycle

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)

        guard let controller = window?.rootViewController as? FlutterViewController else {
            return super.application(application, didFinishLaunchingWithOptions: launchOptions)
        }

        let bleChannel = FlutterMethodChannel(
            name: "com.beconnect.beconnect/ble",
            binaryMessenger: controller.binaryMessenger
        )

        bleChannel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else { return }
            switch call.method {
            case "startAdvertising":
                guard let args       = call.arguments as? [String: Any],
                      let alertJson  = args["alertJson"] as? String,
                      let sevInt     = args["severityByte"] as? Int else {
                    result(FlutterError(code: "INVALID_ARGS", message: nil, details: nil))
                    return
                }
                self.startGateway(alertJson: alertJson, severityByte: UInt8(sevInt))
                result(nil)
            case "stopAdvertising":
                self.stopGateway()
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    // MARK: – Gateway start / stop

    private func startGateway(alertJson: String, severityByte: UInt8) {
        let jsonBytes = Array(alertJson.utf8)
        let total = Int(ceil(Double(jsonBytes.count) / Double(payloadSize)))

        alertChunks = (0 ..< max(total, 1)).map { i in
            let start = i * payloadSize
            let end   = min(start + payloadSize, jsonBytes.count)
            let payload = Array(jsonBytes[start ..< end])
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
