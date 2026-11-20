package com.deviceagent.app

import android.Manifest
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * Native side of `ChannelNames.locationNetwork` — matches Dart's
 * `LocationNetworkBridge`. Returns maps with exactly the field names
 * `DeviceLocation.fromJson`/`DeviceNetwork.fromJson` (Section 11) expect
 * — `latitude`/`longitude`/`accuracy_m`/`timestamp`/`source` and
 * `connected`/`ssid`/`connection_type`/`timestamp` — taaki yeh data
 * seedha `api_client.dart`'s `reportLocation()` ko forward kiya ja sake.
 */
class LocationNetworkHandler(private val activity: HandlerHost) {

    private var pendingPermissionResult: MethodChannel.Result? = null
    private val isoFormat = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("UTC")
    }

    fun register(flutterEngine: FlutterEngine) {
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            ChannelNames.locationNetwork
        )
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "requestPermission" -> requestPermission(result)
                "getLocation" -> getLocation(result)
                "getNetworkStatus" -> result.success(getNetworkStatus())
                "getBattery" -> result.success(getBatteryPercent())
                else -> result.notImplemented()
            }
        }
    }

    /** Item 32: battery % (0-100) ya null agar nahi mil sakta. */
    private fun getBatteryPercent(): Int? {
        val bm = activity.getSystemService(android.content.Context.BATTERY_SERVICE) as? BatteryManager
            ?: return null
        val pct = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        return if (pct in 0..100) pct else null
    }

    private fun hasFineLocation(): Boolean =
        ContextCompat.checkSelfPermission(
            activity, Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED

    /** Item 69: approximate-only (COARSE) permission ko bhi "granted" maante hain. */
    private fun hasLocationPermission(): Boolean =
        hasFineLocation() || ContextCompat.checkSelfPermission(
            activity, Manifest.permission.ACCESS_COARSE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED

    private fun requestPermission(result: MethodChannel.Result) {
        if (hasLocationPermission()) {
            result.success(true)
            return
        }
        activity.requireUi("permission dialog") // headless => NEEDS_UI, pending set hone se pehle
        pendingPermissionResult?.success(false) // item 74: purani request latakni nahi chahiye
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(
            activity.requireUi("permission dialog"),
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION),
            MainActivity.REQUEST_CODE_LOCATION_PERMISSION
        )
    }

    /** MainActivity.onRequestPermissionsResult isko call karta hai. */
    fun onPermissionResult(grantResults: IntArray) {
        // Item 69: Android 12+ par user sirf "approximate" de sakta hai —
        // koi bhi ek grant ho to location milti hai.
        val granted = grantResults.any { it == PackageManager.PERMISSION_GRANTED }
        pendingPermissionResult?.success(granted)
        pendingPermissionResult = null
    }

    private fun getLocation(result: MethodChannel.Result) {
        if (!hasLocationPermission()) {
            result.error("PERMISSION_DENIED", "Location permission nahi hai", null)
            return
        }
        val locationManager = activity.getSystemService(LocationManager::class.java)
        // GPS provider ko FINE permission chahiye; sirf COARSE ho to NETWORK.
        val provider = when {
            hasFineLocation() && locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER) ->
                LocationManager.GPS_PROVIDER
            locationManager.isProviderEnabled(LocationManager.NETWORK_PROVIDER) -> LocationManager.NETWORK_PROVIDER
            else -> null
        }
        val otherProvider = if (provider == LocationManager.GPS_PROVIDER)
            LocationManager.NETWORK_PROVIDER else LocationManager.GPS_PROVIDER
        if (provider == null) {
            result.error("LOCATION_DISABLED", "Koi location provider enabled nahi hai", null)
            return
        }

        // One-shot update — requestLocationUpdates + turant removeUpdates,
        // taaki koi continuous background listener register na rahe (API
        // 30+ ka getCurrentLocation() sabhi supported OS versions par nahi
        // hai, isliye yeh zyada compatible tareeka hai).
        var responded = false
        val mainHandler = Handler(Looper.getMainLooper())
        var timeoutRunnable: Runnable? = null

        val listener = object : LocationListener {
            override fun onLocationChanged(location: Location) {
                if (responded) return
                responded = true
                timeoutRunnable?.let { mainHandler.removeCallbacks(it) }
                locationManager.removeUpdates(this)
                result.success(locationToMap(location))
            }

            @Deprecated("Deprecated in API 29, but override still required pre-29")
            override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
            override fun onProviderEnabled(provider: String) {}
            override fun onProviderDisabled(provider: String) {
                if (responded) return
                responded = true
                timeoutRunnable?.let { mainHandler.removeCallbacks(it) }
                locationManager.removeUpdates(this)
                result.error("LOCATION_DISABLED", "Provider band ho gaya", null)
            }
        }

        try {
            locationManager.requestLocationUpdates(provider, 0L, 0f, listener, Looper.getMainLooper())
        } catch (e: SecurityException) {
            result.error("PERMISSION_DENIED", e.message, null)
            return
        }

        // Item 69: `decorView.postDelayed` activity destroy hone par crash
        // kar sakta tha; ab main-looper Handler. Timeout par pehle chosen
        // provider ka last-known, phir doosre provider ka (GPS fail =>
        // NETWORK fallback), warna TIMEOUT.
        val timeout = Runnable {
            if (responded) return@Runnable
            responded = true
            locationManager.removeUpdates(listener)
            @Suppress("MissingPermission")
            val last = try {
                locationManager.getLastKnownLocation(provider)
                    ?: if (hasFineLocation()) locationManager.getLastKnownLocation(otherProvider) else null
            } catch (e: SecurityException) {
                null
            }
            if (last != null) {
                result.success(locationToMap(last))
            } else {
                result.error("TIMEOUT", "Location fix nahi mila", null)
            }
        }
        timeoutRunnable = timeout
        mainHandler.postDelayed(timeout, 10_000)
    }

    private fun locationToMap(location: Location): Map<String, Any> = mapOf(
        "latitude" to location.latitude,
        "longitude" to location.longitude,
        "accuracy_m" to location.accuracy.toDouble(),
        "timestamp" to isoFormat.format(Date(location.time)),
        "source" to location.provider.orEmpty()
    )

    private fun getNetworkStatus(): Map<String, Any?> {
        val connectivityManager = activity.getSystemService(ConnectivityManager::class.java)
        val network = connectivityManager.activeNetwork
        val capabilities = network?.let { connectivityManager.getNetworkCapabilities(it) }

        val connected = capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
        val connectionType = when {
            capabilities == null -> "NONE"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "WIFI"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "CELLULAR"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ETHERNET"
            else -> "OTHER"
        }

        var ssid: String? = null
        if (connectionType == "WIFI" && hasLocationPermission()) {
            // SSID padhne ke liye location permission chahiye — Android
            // ka apna design (Wi-Fi se location infer ho sakti hai
            // isliye isko location-sensitive data treat kiya gaya hai).
            // Item 69: pehle modern `transportInfo` (API 29+), phir
            // deprecated `connectionInfo` fallback.
            var rawSsid: String? = null
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                rawSsid = (capabilities?.transportInfo as? WifiInfo)?.ssid
            }
            if (rawSsid == null || rawSsid == WifiManager.UNKNOWN_SSID) {
                val wifiManager = activity.applicationContext.getSystemService(WifiManager::class.java)
                @Suppress("DEPRECATION")
                rawSsid = wifiManager?.connectionInfo?.ssid
            }
            ssid = rawSsid?.trim('"').takeIf { it != WifiManager.UNKNOWN_SSID && !it.isNullOrEmpty() }
        }

        return mapOf(
            "connected" to connected,
            "ssid" to ssid,
            "connection_type" to connectionType,
            "timestamp" to isoFormat.format(Date())
        )
    }
}
