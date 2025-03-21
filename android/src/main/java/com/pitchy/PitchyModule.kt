package com.pitchy

import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.WritableMap
import com.facebook.react.modules.core.DeviceEventManagerModule

import android.media.AudioRecord
import android.media.AudioFormat
import android.media.MediaRecorder

import kotlin.concurrent.thread

class PitchyModule(reactContext: ReactApplicationContext) :
  ReactContextBaseJavaModule(reactContext) {

  private var isRecording = false
  private var isInitialized = false
 
  private var audioRecord: AudioRecord? = null
  private var recordingThread: Thread? = null
  
  private var sampleRate: Int = 44100

  private var minVolume: Double = 0.0
  private var bufferSize: Int = 0
  
  private var sliceBuffer = mutableListOf<Short>()
  private var fullRecordingBuffer = mutableListOf<Short>()

  override fun getName(): String {
    return NAME
  }

  @ReactMethod
  fun init(config: ReadableMap) {
      minVolume = config.getDouble("minVolume")
      bufferSize = config.getInt("bufferSize")

      audioRecord = AudioRecord(MediaRecorder.AudioSource.MIC, sampleRate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, bufferSize)

      isInitialized = true
  }

  @ReactMethod
  fun isRecording(promise: Promise) {
      promise.resolve(isRecording)
  }

  @ReactMethod
  fun addListener(eventName: String) {
    // Keep: Required for RN built in Event Emitter Calls.
  }

  @ReactMethod
  fun removeListeners(count: Int) {
    // Keep: Required for RN built in Event Emitter Calls.
  }

  @ReactMethod
  fun start(promise: Promise) {

    if(!isInitialized) {
      promise.reject("E_NOT_INITIALIZED", "Not initialized")
      return
    }

    if (isRecording) {
      promise.reject("E_ALREADY_RECORDING", "Already recording")
      return
    }

    startRecording()
    promise.resolve(true)
  }

  @ReactMethod
  fun stop(promise: Promise) {
    if (!isRecording) {
      promise.reject("E_NOT_RECORDING", "Not recording")
      return
    }

    stopRecording()
    promise.resolve(true)
  }
  
  @ReactMethod
  fun slice(promise: Promise) {
    synchronized(this) {
        if (sliceBuffer.isEmpty()) {
            val result = Arguments.createMap().apply {
                putString("audio", "")
                putDouble("duration", 0.0)
            }
            promise.resolve(result)
            return
        }
        val originalSampleRate = sampleRate  // e.g. 44100
        val requiredSamples = (2.0 * originalSampleRate).toInt()  // 2 seconds of audio

        // Pad the beginning with zeros if necessary
        val paddedSamples: List<Short> = if (sliceBuffer.size < requiredSamples) {
            val padCount = requiredSamples - sliceBuffer.size
            List(padCount) { 0.toShort() } + sliceBuffer
        } else {
            sliceBuffer.toList()
        }
        // Resample from originalSampleRate to 16000 Hz
        val targetSampleRate = 16000
        val resampledSamples = resampleShorts(paddedSamples, originalSampleRate, targetSampleRate)
        // Convert the resampled shorts to a byte array (PCM 16-bit little-endian)
        val pcmBytes = shortsToLittleEndianByteArray(resampledSamples)
        // Create a WAV file with a 16 kHz sample rate, 1 channel, 16-bit PCM
        val wavBytes = createWavFile(pcmBytes, targetSampleRate, 1, 16)
        // Base64 encode the WAV file
        val base64Audio = android.util.Base64.encodeToString(wavBytes, android.util.Base64.NO_WRAP)
        val audioResult = "data:audio/wav;base64,$base64Audio"
        // Calculate duration (in milliseconds) based on resampled samples
        val durationMs = resampledSamples.size.toDouble() / targetSampleRate * 1000
        // Clear the slice buffer after slicing
        sliceBuffer.clear()

        val result = Arguments.createMap().apply {
            putString("audio", audioResult)
            putDouble("duration", durationMs)
        }
        promise.resolve(result)
    }
  }
  
  @ReactMethod
  fun saveRecording(filename: String, promise: Promise) {
    synchronized(this) {
        if (fullRecordingBuffer.isEmpty()) {
            promise.reject("no_data", "No recording data available")
            return
        }
        // Convert the full recording buffer (PCM 16-bit) to a byte array.
        val pcmBytes = shortsToLittleEndianByteArray(fullRecordingBuffer)
        // Create a WAV file using the original sample rate, 1 channel, 16-bit PCM.
        val wavBytes = createWavFile(pcmBytes, sampleRate, 1, 16)
        try {
            val file = java.io.File(reactApplicationContext.filesDir, "$filename.wav")
            file.writeBytes(wavBytes)
            // Clear the full recording buffer after saving.
            fullRecordingBuffer.clear()
            promise.resolve(file.absolutePath)
        } catch(e: Exception) {
            promise.reject("save_error", "Failed to save recording", e)
        }
    }
  }

  private fun startRecording(){
    audioRecord?.startRecording()
    isRecording = true

    recordingThread = thread(start = true) {
    val buffer = ShortArray(bufferSize)
    while (isRecording) {
        val read = audioRecord?.read(buffer, 0, bufferSize)
        if (read != null && read > 0) {
            detectPitch(buffer)
            synchronized(this) {
                for (i in 0 until read) {
                    sliceBuffer.add(buffer[i])
                    //fullRecordingBuffer.add(buffer[i])
                }
            }
        }
      }
    }
  }

  private fun stopRecording() {
    isRecording = false
    audioRecord?.stop()
    audioRecord?.release()
    audioRecord = null
    recordingThread?.interrupt()
    recordingThread = null
  }

  private external fun nativeAutoCorrelate(buffer: ShortArray, sampleRate: Int, minVolume: Double): Double

  private fun detectPitch(buffer: ShortArray){
    val pitch = nativeAutoCorrelate(buffer, sampleRate, minVolume)
    val params: WritableMap = Arguments.createMap()
    params.putDouble("pitch", pitch)
    reactApplicationContext.getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java).emit("onPitchDetected", params)
  }
  
    private fun createWavFile(pcmData: ByteArray, sampleRate: Int, channels: Int, bitsPerSample: Int): ByteArray {
    val byteRate = sampleRate * channels * bitsPerSample / 8
    val blockAlign = channels * bitsPerSample / 8
    val pcmDataLength = pcmData.size
    val chunkSize = 36 + pcmDataLength

    val header = java.nio.ByteBuffer.allocate(44)
    header.order(java.nio.ByteOrder.LITTLE_ENDIAN)
    header.put("RIFF".toByteArray(Charsets.US_ASCII))
    header.putInt(chunkSize)
    header.put("WAVE".toByteArray(Charsets.US_ASCII))
    header.put("fmt ".toByteArray(Charsets.US_ASCII))
    header.putInt(16) // PCM subchunk size
    header.putShort(1.toShort()) // Audio format (PCM)
    header.putShort(channels.toShort())
    header.putInt(sampleRate)
    header.putInt(byteRate)
    header.putShort(blockAlign.toShort())
    header.putShort(bitsPerSample.toShort())
    header.put("data".toByteArray(Charsets.US_ASCII))
    header.putInt(pcmDataLength)
    val headerBytes = header.array()

    val wavData = ByteArray(headerBytes.size + pcmData.size)
    System.arraycopy(headerBytes, 0, wavData, 0, headerBytes.size)
    System.arraycopy(pcmData, 0, wavData, headerBytes.size, pcmData.size)
    return wavData
  }
  
  private fun resampleShorts(input: List<Short>, originalRate: Int, targetRate: Int): List<Short> {
    if (originalRate == targetRate) return input
    val ratio = originalRate.toDouble() / targetRate
    val outputSize = (input.size / ratio).toInt()
    val output = ArrayList<Short>(outputSize)
    for (i in 0 until outputSize) {
        val srcIndex = (i * ratio).toInt()
        output.add(input.getOrElse(srcIndex) { 0 })
    }
    return output
  }

  private fun shortsToLittleEndianByteArray(shorts: List<Short>): ByteArray {
    val byteBuffer = java.nio.ByteBuffer.allocate(shorts.size * 2)
    byteBuffer.order(java.nio.ByteOrder.LITTLE_ENDIAN)
    for (s in shorts) {
        byteBuffer.putShort(s)
    }
    return byteBuffer.array()
  }

  companion object {
    const val NAME = "Pitchy"
    init {
      System.loadLibrary("react-native-pitchy")
    }
  }
}