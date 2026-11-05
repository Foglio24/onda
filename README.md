# Android builds

APKs of Seaglass for Android signed with the release key, one folder per version. The Android
workflow publishes them as a release's files when the `ANDROID_SIGNING_KEY` secret isn't set, after
checking that their signature is the certificate in `android/signing/seaglass-cert.pem` and that
their version is the one being released. Download the app from the Releases page, not from here.
