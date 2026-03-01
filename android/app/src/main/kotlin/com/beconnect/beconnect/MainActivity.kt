package com.beconnect.beconnect

import android.Manifest
import android.bluetooth.*
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.pm.PackageManager
import android.os.Build
import android.os.ParcelUuid
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "com.beconnect.beconnect/ble"
        private val SERVICE_UUID   = UUID.fromString("0000BCBC-0000-1000-8000-00805F9B34FB")
        private val ALERT_CHAR_UUID   = UUID.fromString("0000BCB1-0000-1000-8000-00805F9B34FB")
        private val CONTROL_CHAR_UUID = UUID.fromString("0000BCB2-0000-1000-8000-00805F9B34FB")
        private const val MANUFACTURER_ID = 0x1234
        private const val PAYLOAD_SIZE = 508
    }

    private var gattServer: BluetoothGattServer? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var alertChunks: List<ByteArray> = emptyList()
    private val pendingChunkIndex = mutableMapOf<String, Int>()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startAdvertising" -> {
                        val alertBytes   = call.argument<ByteArray>("alertBytes") ?: byteArrayOf()
                        val severityByte = (call.argument<Int>("severityByte") ?: 4).toByte()
                        startGateway(alertBytes, severityByte, result)
                    }
                    "stopAdvertising" -> stopGateway(result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun hasPermission(permission: String): Boolean {
        return ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED
    }

    private fun checkBluetoothPermissions(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            hasPermission(Manifest.permission.BLUETOOTH_ADVERTISE) && 
            hasPermission(Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            true 
        }
    }

    private fun startGateway(alertBytes: ByteArray, severityByte: Byte, result: MethodChannel.Result) {
        val bluetoothManager = getSystemService(BLUETOOTH_SERVICE) as BluetoothManager
        val adapter = bluetoothManager.adapter

        if (adapter == null || !adapter.isEnabled) {
            result.error("BLE_ERROR", "Bluetooth is disabled or not supported", null)
            return
        }

        if (!checkBluetoothPermissions()) {
            result.error("PERMISSION_ERROR", "Bluetooth permissions not granted", null)
            return
        }

        // alertBytes arrives pre-compressed (gzip) from Dart — no UTF-8 conversion needed.
        val total = Math.ceil(alertBytes.size.toDouble() / PAYLOAD_SIZE).toInt().coerceAtLeast(1)
        alertChunks = (0 until total).map { i ->
            val start   = i * PAYLOAD_SIZE
            val end     = minOf(start + PAYLOAD_SIZE, alertBytes.size)
            val payload = alertBytes.copyOfRange(start, end)
            byteArrayOf(
                ((i shr 8) and 0xFF).toByte(), (i and 0xFF).toByte(),
                ((total shr 8) and 0xFF).toByte(), (total and 0xFF).toByte()
            ) + payload
        }

        try {
            gattServer = bluetoothManager.openGattServer(this, gattServerCallback)
            val alertChar = BluetoothGattCharacteristic(
                ALERT_CHAR_UUID,
                BluetoothGattCharacteristic.PROPERTY_READ,
                BluetoothGattCharacteristic.PERMISSION_READ
            )
            val controlChar = BluetoothGattCharacteristic(
                CONTROL_CHAR_UUID,
                BluetoothGattCharacteristic.PROPERTY_WRITE,
                BluetoothGattCharacteristic.PERMISSION_WRITE
            )
            val service = BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
            service.addCharacteristic(alertChar)
            service.addCharacteristic(controlChar)
            gattServer?.addService(service)

            advertiser = adapter.bluetoothLeAdvertiser
            if (advertiser == null) {
                result.error("BLE_ERROR", "Device does not support BLE advertising", null)
                return
            }

            val settings = AdvertiseSettings.Builder()
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
                .setConnectable(true)
                .setTimeout(0)
                .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
                .build()
            val data = AdvertiseData.Builder()
                .setIncludeDeviceName(false)
                .addServiceUuid(ParcelUuid(SERVICE_UUID))
                .addManufacturerData(MANUFACTURER_ID, byteArrayOf(severityByte))
                .build()
            
            advertiser?.startAdvertising(settings, data, advertiseCallback)
            result.success(null)
        } catch (e: SecurityException) {
            result.error("SECURITY_EXCEPTION", e.message, null)
        } catch (e: Exception) {
            result.error("UNKNOWN_ERROR", e.message, null)
        }
    }

    private fun stopGateway(result: MethodChannel.Result) {
        try {
            advertiser?.stopAdvertising(advertiseCallback)
            gattServer?.close()
        } catch (e: Exception) {
        } finally {
            advertiser     = null
            gattServer     = null
            alertChunks    = emptyList()
            pendingChunkIndex.clear()
            result.success(null)
        }
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {}
        override fun onStartFailure(errorCode: Int) {}
    }

    private val gattServerCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                pendingChunkIndex.remove(device.address)
            }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray
        ) {
            if (characteristic.uuid == CONTROL_CHAR_UUID && value.size >= 2) {
                val idx = ((value[0].toInt() and 0xFF) shl 8) or (value[1].toInt() and 0xFF)
                pendingChunkIndex[device.address] = idx
                if (responseNeeded) {
                    try {
                        gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
                    } catch (e: SecurityException) {}
                }
            }
        }

        override fun onCharacteristicReadRequest(
            device: BluetoothDevice,
            requestId: Int,
            offset: Int,
            characteristic: BluetoothGattCharacteristic
        ) {
            if (characteristic.uuid != ALERT_CHAR_UUID) return

            val idx = pendingChunkIndex[device.address] ?: 0
            if (idx < 0 || idx >= alertChunks.size) {
                try {
                    gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, 0, null)
                } catch (e: SecurityException) {}
                return
            }
            val frame = alertChunks[idx]
            val responseData = if (offset < frame.size) frame.copyOfRange(offset, frame.size)
                               else byteArrayOf()
            try {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, responseData)
            } catch (e: SecurityException) {}
        }
    }
}
