package dk.nota.flutter_readium.events

import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

class ErrorEventChannel(messenger: BinaryMessenger) :
    EventChannelWrapper<ReadiumErrorEvent>(messenger, "dk.nota.flutter_readium/error") {
    override fun sendEvent(data: ReadiumErrorEvent) {
        mainScope.launch {
            Log.d("ErrorEventChannel", ":sendEvent $data")
            eventSink?.success(Json.encodeToString(data))
        }
    }
}

@Serializable
data class ReadiumErrorEvent(
    val message: String,
    val code: String? = null,
    val data: String? = null,
)
