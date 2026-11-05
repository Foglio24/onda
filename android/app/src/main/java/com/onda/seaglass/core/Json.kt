package com.onda.seaglass.core

import org.json.JSONArray
import org.json.JSONObject

/** Tiny helpers for digging through loosely typed JSON (InnerTube responses), like the iPhone app's `J`. */
object J {
    /** Follows a path of object keys (`String`) and array positions (`Int`). */
    fun value(root: Any?, vararg path: Any): Any? {
        var current = root
        for (component in path) {
            current = when (component) {
                is String -> (current as? JSONObject)?.opt(component)
                is Int -> (current as? JSONArray)?.let { if (component in 0 until it.length()) it.opt(component) else null }
                else -> null
            }
            if (current == null || current == JSONObject.NULL) return null
        }
        return current
    }

    fun string(root: Any?, vararg path: Any): String? = value(root, *path) as? String

    fun obj(root: Any?, vararg path: Any): JSONObject? = value(root, *path) as? JSONObject

    fun array(root: Any?, vararg path: Any): List<Any> {
        val array = value(root, *path) as? JSONArray ?: return emptyList()
        return (0 until array.length()).mapNotNull { array.opt(it)?.takeUnless { item -> item == JSONObject.NULL } }
    }

    fun objects(root: Any?, vararg path: Any): List<JSONObject> = array(root, *path).filterIsInstance<JSONObject>()

    /** Every object stored under [key] anywhere below [root], in document order. */
    fun findAll(key: String, root: Any?): List<JSONObject> {
        val results = mutableListOf<JSONObject>()
        fun walk(node: Any?) {
            when (node) {
                is JSONObject -> for (name in node.keys()) {
                    val child = node.opt(name)
                    if (name == key && child is JSONObject) results.add(child) else walk(child)
                }
                is JSONArray -> for (i in 0 until node.length()) walk(node.opt(i))
            }
        }
        walk(root)
        return results
    }

    fun first(key: String, root: Any?): JSONObject? = findAll(key, root).firstOrNull()

    /** The text of a `{"runs": [...]}` object. */
    fun text(value: Any?): String? {
        val runs = objects(value, "runs").mapNotNull { it.optString("text").takeIf(String::isNotEmpty) }
        return if (runs.isEmpty()) null else runs.joinToString("")
    }
}

fun jsonOf(vararg pairs: Pair<String, Any?>): JSONObject = JSONObject().apply {
    for ((key, value) in pairs) if (value != null) put(key, value)
}
