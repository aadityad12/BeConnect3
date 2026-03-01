package com.beconnect.beconnect

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.bluetooth.*
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.ParcelUuid
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

class MainActivity : FlutterActivity() {

    companion object {
        private const val TAG = "BeConnectNative"
        private const val CHANNEL_ID = "beconnect_bg_channel"
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

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createNotificationChannel()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val name = "BeConnect Background Service"
            val descriptionText = "Used for BLE advertising in the background"
            val importance = NotificationManager.IMPORTANCE_LOW
            val channel = NotificationChannel(CHANNEL_ID, name, importance).apply {
                description = descriptionText
            }
            val notificationManager: NotificationManager =
                getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.createNotificationChannel(channel)
            Log.d(TAG, "Notification channel created: $CHANNEL_ID")
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        Log.d(TAG, "Configuring Flutter Engine")

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startAdvertising" -> {
                        val alertJson   = call.argument<String>("alertJson") ?: ""
                        val severityByte = (call.argument<Int>("severityByte") ?: 4).toByte()
                        startGateway(alertJson, severityByte, result)
                    }
                    "stopAdvertising" -> stopGateway(result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun hasPermission(permission: String): Boolean {
        val status = ContextCompat.checkSelfPermission(this, permission)
        Log.d(TAG, "Permission $permission status: $status")
        return status == PackageManager.PERMISSION_GRANTED
    }

    private fun checkBluetoothPermissions(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            hasPermission(Manifest.permission.BLUETOOTH_ADVERTISE) && 
            hasPermission(Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            true 
        }
    }

    private fun startGateway(alertJson: String, severityByte: Byte, result: MethodChannel.Result) {
        Log.d(TAG, "Starting Gateway")
        val bluetoothManager = getSystemService(BLUETOOTH_SERVICE) as BluetoothManager
        val adapter = bluetoothManager.adapter

        if (adapter == null || !adapter.isEnabled) {
            Log.e(TAG, "Bluetooth disabled or not supported")
            result.error("BLE_ERROR", "Bluetooth is disabled or not supported", null)
            return
        }

        if (!checkBluetoothPermissions()) {
            Log.e(TAG, "Permissions not granted")
            result.error("PERMISSION_ERROR", "Bluetooth permissions not granted", null)
            return
        }

        val jsonBytes = alertJson.toByteArray(Charsets.UTF_8)
        val total = Math.ceil(jsonBytes.size.toDouble() / PAYLOAD_SIZE).toInt().coerceAtLeast(1)
        alertChunks = (0 until total).map { i ->
            val start   = i * PAYLOAD_SIZE
            val end     = minOf(start + PAYLOAD_SIZE, jsonBytes.size)
            val payload = jsonBytes.copyOfRange(start, end)
            byteArrayOf(
                ((i shr 8) and 0xFF).toByte(), (i and 0xFF).toByte(),
                ((total shr 8) and 0xFF).toByte(), (total and 0xFF).toByte()
            ) + payload
        }

        try {
            Log.d(TAG, "Opening GATT Server")
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
                Log.e(TAG, "Advertising not supported")
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
            Log.d(TAG, "Advertising started successfully")
            result.success(null)
        } catch (e: SecurityException) {
            Log.e(TAG, "SecurityException: ${e.message}")
            result.error("SECURITY_EXCEPTION", e.message, null)
        } catch (e: Exception) {
            Log.e(TAG, "Exception: ${e.message}")
            result.error("UNKNOWN_ERROR", e.message, null)
        }
    }

    private fun stopGateway(result: MethodChannel.Result) {
        Log.d(TAG, "Stopping Gateway")
        try {
            advertiser?.stopAdvertising(advertiseCallback)
            gattServer?.close()
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping: ${e.message}")
        } finally {
            advertiser     = null
            gattServer     = null
            alertChunks    = emptyList()
            pendingChunkIndex.clear()
            result.success(null)
        }
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
            Log.d(TAG, "onStartSuccess")
        }
        override fun onStartFailure(errorCode: Int) {
            Log.e(TAG, "onStartFailure: $errorCode")
        }
    }

    private val gattServerCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            Log.d(TAG, "onConnectionStateChange: ${device.address} -> $newState")
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
