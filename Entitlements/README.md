# Entitlements

Seaglass is built unsigned (CI) and signed by whoever installs it. These files only declare what the
app and its widgets need, so the signing tools can grant it:

- `Seaglass.entitlements`, `SeaglassWidgets.entitlements`: the App Group the app and its widgets
  share (`group.com.onda.player`). build.yml writes them into the IPA's binaries with `ldid`, as
  unsigned sideloaded apps do: AltStore and SideStore read them there, create the group for the
  signer's team (under a name of their own, listed in the app's Info.plist as `ALTAppGroups`, which
  Shared/WidgetShared.swift reads) and sign the app with it.

The Mac app has no widgets: macOS loads a widget extension only from inside the sandbox, and the Mac
app is signed ad hoc, anew at each version, so macOS would ask after every update whether the widget
may open its own data (the reason the app itself isn't sandboxed: see build.yml).

Nothing here is a secret, and no certificate or profile is ever kept in the repository.
