package com.deviceagent.app

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.os.Build
import android.os.Bundle
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Native side of `ChannelNames.input` ("device_agent/input") — matches
 * `InputBridge` in Dart. AccessibilityService Android ka sirf reliable,
 * non-root tareeka hai tap/swipe/type synthesize karne ka.
 *
 * User ko yeh service khud Settings > Accessibility mein enable karni
 * padti hai — Android is step ko skip nahi hone deta (jaise Screen
 * Capture ke MediaProjection dialog ko skip nahi kiya ja sakta).
 */
class InputAccessibilityService : AccessibilityService() {

    companion object {
        var instance: InputAccessibilityService? = null
            private set
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // Is service ko UI events sunne ki zaroorat nahi — sirf actions
        // dispatch karta hai, isliye yahan kuch nahi karna.
    }

    override fun onInterrupt() {}

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    /** `input.tap` — single point par tap gesture. */
    fun tap(x: Float, y: Float, onDone: (Boolean) -> Unit) {
        val path = Path().apply { moveTo(x, y) }
        val stroke = GestureDescription.StrokeDescription(path, 0, 20)
        val gesture = GestureDescription.Builder().addStroke(stroke).build()
        // Item 65: dispatchGesture khud `false` de sakta hai (gesture queue hi
        // nahi hua) — us case mein callback kabhi nahi aata, isliye
        // yahin `onDone(false)`.
        val dispatched = dispatchGesture(gesture, object : GestureResultCallback() {
            override fun onCompleted(gestureDescription: GestureDescription?) {
                onDone(true)
            }
            override fun onCancelled(gestureDescription: GestureDescription?) {
                onDone(false)
            }
        }, null)
        if (!dispatched) onDone(false)
    }

    /** `input.swipe` — (x1,y1) se (x2,y2) tak, given duration mein. */
    fun swipe(x1: Float, y1: Float, x2: Float, y2: Float, durationMs: Long, onDone: (Boolean) -> Unit) {
        val path = Path().apply {
            moveTo(x1, y1)
            lineTo(x2, y2)
        }
        val stroke = GestureDescription.StrokeDescription(path, 0, durationMs)
        val gesture = GestureDescription.Builder().addStroke(stroke).build()
        // Item 65: dispatchGesture khud `false` de sakta hai (gesture queue hi
        // nahi hua) — us case mein callback kabhi nahi aata, isliye
        // yahin `onDone(false)`.
        val dispatched = dispatchGesture(gesture, object : GestureResultCallback() {
            override fun onCompleted(gestureDescription: GestureDescription?) {
                onDone(true)
            }
            override fun onCancelled(gestureDescription: GestureDescription?) {
                onDone(false)
            }
        }, null)
        if (!dispatched) onDone(false)
    }

    /**
     * `input.type_text` — currently focused editable field mein text set
     * karta hai. (Gesture-based per-key typing ke bajaye ACTION_SET_TEXT
     * use kiya kyunki yeh IME-independent aur zyada reliable hai.)
     */
    /** Back / Home / Recents / Notifications (AccessibilityService global actions). */
    fun pressKey(key: String): Boolean {
        val action = when (key) {
            "back" -> GLOBAL_ACTION_BACK
            "home" -> GLOBAL_ACTION_HOME
            "recents" -> GLOBAL_ACTION_RECENTS
            "notifications" -> GLOBAL_ACTION_NOTIFICATIONS
            else -> return false
        }
        return performGlobalAction(action)
    }

    fun typeText(text: String, append: Boolean = false): Boolean {
        val focused = findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return false
        // Item 66: append => maujooda text ke baad jodo (hint text ko
        // maujooda text na samjho).
        val base = if (append && !(Build.VERSION.SDK_INT >= 26 && focused.isShowingHintText)) {
            focused.text?.toString() ?: ""
        } else ""
        val arguments = Bundle().apply {
            putCharSequence(
                AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                base + text
            )
        }
        val result = focused.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, arguments)
        focused.recycle()
        return result
    }

    // ---- Browser/semantic-tree control (Section: Browser Automation) ----
    //
    // Root/adb ke bina Android par CDP jaisi control possible nahi hai —
    // lekin Chrome (aur zyada-tar browsers) web-page content ko Android
    // Accessibility API ke through poori tarah expose karte hain. Isse
    // hum coordinates guess kiye bina, **text/label se elements dhoond
    // kar** click/type kar sakte hain — asli browser, asli login session
    // ke saath (koi alag automation-browser nahi khulta).

    /** Active window ke poore node-tree mein text/description se match dhoondta hai. */
    private fun findNodeByText(text: String): AccessibilityNodeInfo? {
        val root = rootInActiveWindow ?: return null
        // exact match pehle, phir contains — kyunki buttons/links ka
        // text kabhi exact nahi milta (extra whitespace, icons waghera).
        root.findAccessibilityNodeInfosByText(text)?.firstOrNull()?.let { return it }
        return findNodeRecursive(root) { node ->
            val desc = node.contentDescription?.toString()
            val nodeText = node.text?.toString()
            (nodeText != null && nodeText.contains(text, ignoreCase = true)) ||
                (desc != null && desc.contains(text, ignoreCase = true))
        }
    }

    private fun findNodeRecursive(
        node: AccessibilityNodeInfo,
        predicate: (AccessibilityNodeInfo) -> Boolean
    ): AccessibilityNodeInfo? {
        if (predicate(node)) return node
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val found = findNodeRecursive(child, predicate)
            if (found != null) return found
            // Match nahi mila is child (ya uske kisi descendant) mein —
            // recycle kar dete hain. minSdk 26 par `recycle()` abhi bhi
            // asal resource release karta hai (API 33+ par no-op ban jaata
            // hai) — pehle yahan kabhi recycle nahi hota tha, poore
            // node-tree traversal (jo `getVisibleText()`/`findNodeByText()`
            // har baar poori page par chalate hain) se accumulate hone wala
            // ek real leak tha, khaaskar Android 8–12 devices par.
            child.recycle()
        }
        return null
    }

    /** Text/label se element dhoond kar click karta hai — Browser capability ka core. */
    fun findAndClick(text: String): Boolean {
        val node = findNodeByText(text) ?: return false
        // Jo node text-match hua woh khud clickable na ho (jaise ek span
        // ke andar ka text) — parent chain mein pehla clickable ancestor
        // dhoondte hain. Har `.parent` call ek NAYA node object allocate
        // karta hai — is liye intermediate ancestors bhi recycle karte
        // hain (sirf `node` recycle karna kaafi nahi tha, walked-up chain
        // ke beech ke nodes leak ho rahe the).
        var target: AccessibilityNodeInfo? = node
        while (target != null && !target.isClickable) {
            val parent = target.parent
            if (target !== node) target.recycle()
            target = parent
        }
        val finalTarget = target ?: node
        val result = finalTarget.performAction(AccessibilityNodeInfo.ACTION_CLICK)
        if (finalTarget !== node) finalTarget.recycle()
        node.recycle()
        return result
    }

    /** Label/hint se input field dhoond kar text set karta hai. */
    fun findAndType(fieldLabel: String, text: String): Boolean {
        val node = findNodeByText(fieldLabel) ?: return false
        var target: AccessibilityNodeInfo? = node
        while (target != null && !target.isEditable) {
            val parent = target.parent
            if (target !== node) target.recycle()
            target = parent
        }
        val editable = target ?: run {
            node.recycle()
            return false
        }
        val arguments = Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
        }
        val result = editable.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, arguments)
        if (editable !== node) editable.recycle()
        node.recycle()
        return result
    }

    /** Poore visible page ka text — AI agent isse page samajh sakta hai. */
    fun getVisibleText(): String {
        val root = rootInActiveWindow ?: return ""
        val sb = StringBuilder()
        collectText(root, sb)
        return sb.toString().trim()
    }

    private fun collectText(node: AccessibilityNodeInfo, sb: StringBuilder) {
        node.text?.let { if (it.isNotBlank()) sb.append(it).append('\n') }
        for (i in 0 until node.childCount) {
            node.getChild(i)?.let { collectText(it, sb) }
        }
    }
}
