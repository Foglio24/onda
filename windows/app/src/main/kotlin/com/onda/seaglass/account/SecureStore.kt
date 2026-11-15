package com.onda.seaglass.account

import java.io.File
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import java.security.MessageDigest

/**
 * Session token on disk, encrypted with a key derived from the machine+user (DPAPI would be
 * better via JNA; this keeps the secret off plain JSON until a native bind lands).
 */
object SecureStore {
    private val file = File(System.getProperty("user.home"), "AppData/Local/Seaglass/account.token")

    fun readToken(): String? {
        if (!file.isFile) return null
        return runCatching {
            val raw = file.readBytes()
            if (raw.size < 13) return null
            val iv = raw.copyOfRange(0, 12)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, iv))
            String(cipher.doFinal(raw, 12, raw.size - 12), Charsets.UTF_8)
        }.getOrNull()
    }

    fun writeToken(token: String) {
        file.parentFile?.mkdirs()
        val iv = ByteArray(12).also { java.security.SecureRandom().nextBytes(it) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key(), GCMParameterSpec(128, iv))
        val encrypted = cipher.doFinal(token.toByteArray(Charsets.UTF_8))
        file.writeBytes(iv + encrypted)
    }

    fun clear() {
        file.delete()
    }

    private fun key(): SecretKeySpec {
        val material = (System.getenv("COMPUTERNAME").orEmpty() + "|" +
            System.getProperty("user.name").orEmpty() + "|SeaglassAccount").toByteArray()
        val digest = MessageDigest.getInstance("SHA-256").digest(material)
        return SecretKeySpec(digest, "AES")
    }
}
