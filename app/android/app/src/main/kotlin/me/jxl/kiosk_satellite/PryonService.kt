package me.jxl.kiosk_satellite

/**
 * Whether the ROM runs Amazon's wake word engine as a service, on the
 * biscuit-pryon socket (PryonCatalog).
 *
 * The Echo Dot image says so with `ro.biscuit.pryon`, the Echo Show images
 * with `ro.echo.pryon`. Both run the same service, so the engine is offered
 * with a screen and without one.
 */
object PryonService {
    val properties = listOf("ro.biscuit.pryon", "ro.echo.pryon")

    fun detect(property: (String) -> String): Boolean =
        properties.any { property(it) == "1" }

    val available: Boolean by lazy { detect(Headless::property) }
}
