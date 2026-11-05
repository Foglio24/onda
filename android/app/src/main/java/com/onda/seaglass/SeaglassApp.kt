package com.onda.seaglass

import android.app.Application
import coil3.ImageLoader
import coil3.PlatformContext
import coil3.SingletonImageLoader
import coil3.network.okhttp.OkHttpNetworkFetcherFactory
import coil3.request.crossfade
import com.onda.seaglass.core.Http
import com.onda.seaglass.core.L10n
import com.onda.seaglass.data.Library
import com.onda.seaglass.data.Prefs
import com.onda.seaglass.data.Recommendations
import com.onda.seaglass.playback.PlayerController

class SeaglassApp : Application(), SingletonImageLoader.Factory {
    override fun onCreate() {
        super.onCreate()
        L10n.load(this)
        Prefs.init(this)
        Library.init(this)
        Recommendations.init(this)
        PlayerController.init(this)
    }

    override fun newImageLoader(context: PlatformContext): ImageLoader =
        ImageLoader.Builder(context)
            .components { add(OkHttpNetworkFetcherFactory(callFactory = { Http.client })) }
            .crossfade(true)
            .build()
}
