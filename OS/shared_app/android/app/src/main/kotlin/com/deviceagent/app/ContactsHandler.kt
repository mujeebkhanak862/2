package com.deviceagent.app

import android.Manifest
import android.content.pm.PackageManager
import android.provider.ContactsContract
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Native side of `ChannelNames.contacts` — matches Dart's
 * `ContactsBridge`. **Read-only** — koi write/delete action support nahi
 * karta (permission scope minimal rakhne ke liye, Section 3.5 spirit).
 */
class ContactsHandler(private val activity: HandlerHost) {

    private var pendingPermissionResult: MethodChannel.Result? = null

    fun register(flutterEngine: FlutterEngine) {
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            ChannelNames.contacts
        )
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "isAvailable" -> result.success(true)
                "requestPermission" -> requestPermission(result)
                "listContacts" -> listContacts(result)
                else -> result.notImplemented()
            }
        }
    }

    private fun hasPermission(): Boolean =
        ContextCompat.checkSelfPermission(
            activity, Manifest.permission.READ_CONTACTS
        ) == PackageManager.PERMISSION_GRANTED

    private fun requestPermission(result: MethodChannel.Result) {
        if (hasPermission()) {
            result.success(true)
            return
        }
        activity.requireUi("permission dialog") // headless => NEEDS_UI, pending set hone se pehle
        pendingPermissionResult?.success(false) // item 74
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(
            activity.requireUi("permission dialog"),
            arrayOf(Manifest.permission.READ_CONTACTS),
            MainActivity.REQUEST_CODE_CONTACTS_PERMISSION
        )
    }

    /** MainActivity.onRequestPermissionsResult isko call karta hai. */
    fun onPermissionResult(grantResults: IntArray) {
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingPermissionResult?.success(granted)
        pendingPermissionResult = null
    }

    private val executor = java.util.concurrent.Executors.newSingleThreadExecutor()

    /**
     * Item 70: contacts load pehle poore main thread par hota tha (bade
     * address book par ANR). Ab background thread; result UI thread par.
     * Safety cap: max 5000 contacts.
     */
    private fun listContacts(result: MethodChannel.Result) {
        if (!hasPermission()) {
            result.error("PERMISSION_DENIED", "Contacts permission nahi hai", null)
            return
        }
        executor.execute {
            try {
                val list = loadContacts()
                activity.runOnUiThread { result.success(list) }
            } catch (e: Exception) {
                activity.runOnUiThread { result.error("CONTACTS_FAILED", e.message, null) }
            }
        }
    }

    private fun loadContacts(): List<Map<String, Any>> {

        val contacts = LinkedHashMap<String, MutableMap<String, Any>>()
        val resolver = activity.contentResolver

        // Step 1: naam + id.
        resolver.query(
            ContactsContract.Contacts.CONTENT_URI,
            arrayOf(ContactsContract.Contacts._ID, ContactsContract.Contacts.DISPLAY_NAME),
            null, null, null
        )?.use { cursor ->
            val idCol = cursor.getColumnIndexOrThrow(ContactsContract.Contacts._ID)
            val nameCol = cursor.getColumnIndexOrThrow(ContactsContract.Contacts.DISPLAY_NAME)
            while (cursor.moveToNext() && contacts.size < 5000) {
                val id = cursor.getString(idCol)
                contacts[id] = mutableMapOf(
                    "id" to id,
                    "name" to (cursor.getString(nameCol) ?: ""),
                    "phoneNumbers" to mutableListOf<String>(),
                    "emails" to mutableListOf<String>()
                )
            }
        }

        // Step 2: phone numbers, ContactId se map karte hain.
        resolver.query(
            ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
            arrayOf(
                ContactsContract.CommonDataKinds.Phone.CONTACT_ID,
                ContactsContract.CommonDataKinds.Phone.NUMBER
            ),
            null, null, null
        )?.use { cursor ->
            val idCol = cursor.getColumnIndexOrThrow(ContactsContract.CommonDataKinds.Phone.CONTACT_ID)
            val numCol = cursor.getColumnIndexOrThrow(ContactsContract.CommonDataKinds.Phone.NUMBER)
            while (cursor.moveToNext()) {
                val id = cursor.getString(idCol)
                val number = cursor.getString(numCol) ?: continue
                @Suppress("UNCHECKED_CAST")
                (contacts[id]?.get("phoneNumbers") as? MutableList<String>)?.add(number)
            }
        }

        // Step 3: emails.
        resolver.query(
            ContactsContract.CommonDataKinds.Email.CONTENT_URI,
            arrayOf(
                ContactsContract.CommonDataKinds.Email.CONTACT_ID,
                ContactsContract.CommonDataKinds.Email.ADDRESS
            ),
            null, null, null
        )?.use { cursor ->
            val idCol = cursor.getColumnIndexOrThrow(ContactsContract.CommonDataKinds.Email.CONTACT_ID)
            val emailCol = cursor.getColumnIndexOrThrow(ContactsContract.CommonDataKinds.Email.ADDRESS)
            while (cursor.moveToNext()) {
                val id = cursor.getString(idCol)
                val email = cursor.getString(emailCol) ?: continue
                @Suppress("UNCHECKED_CAST")
                (contacts[id]?.get("emails") as? MutableList<String>)?.add(email)
            }
        }

        return contacts.values.toList()
    }
}
