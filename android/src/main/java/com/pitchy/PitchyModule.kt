package com.pitchy

import com.facebook.react.bridge.*
import com.facebook.react.modules.core.DeviceEventManagerModule

import android.media.AudioRecord
import android.media.AudioFormat
import android.media.MediaRecorder
import android.media.MediaCodec
import android.media.MediaFormat
import android.media.MediaCodecInfo
import android.media.MediaMuxer

import kotlin.concurrent.thread

class PitchyModule(reactContext: ReactApplicationContext) :
  ReactContextBaseJavaModule(reactContext) {

  private var isRecording = false
  private var isInitialized = false
  private var isPaused = false
  private var recordFullAudio = false

  private var audioRecord: AudioRecord? = null
  private var recordingThread: Thread? = null

  private var sampleRate: Int = 44100
  private var minVolume: Double = 0.0
  private var bufferSize: Int = 0
  private val maxSliceDurationSeconds = 20
  private val maxFullRecordingDurationSeconds = 300

  private var sliceBuffer = mutableListOf<Short>()
  private var fullRecordingBuffer = mutableListOf<Short>()

  override fun getName(): String {
    return NAME
  }

  @ReactMethod
  fun init(config: ReadableMap) {
      minVolume = config.getDouble("minVolume")
      bufferSize = config.getInt("bufferSize")
      recordFullAudio = if (config.hasKey("recordFullAudio")) config.getBoolean("recordFullAudio") else false

      audioRecord = AudioRecord(
       MediaRecorder.AudioSource.MIC,
       sampleRate,
       AudioFormat.CHANNEL_IN_MONO,
       AudioFormat.ENCODING_PCM_16BIT,
       bufferSize)

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

    sliceBuffer.clear()
    fullRecordingBuffer.clear()
    isPaused = false

    startRecording()
    promise.resolve(true)
  }

  @ReactMethod
  fun pause(promise: Promise) {
      if (!isRecording) {
        promise.reject("E_NOT_RECORDING", "Not recording");
        return
      }

      isPaused = true
      synchronized(this) {
        sliceBuffer.clear()
      }
      promise.resolve(true)
  }

  @ReactMethod
  fun resume(promise: Promise) {
      if (!isRecording) {
        promise.reject("E_NOT_RECORDING", "Not recording");
        return
      }
      isPaused = false
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
    // Backwards-compat: default WAV save
    saveRecordingWav(filename, promise)
  }

  @ReactMethod
  fun saveRecordingWithOptions(filename: String, options: ReadableMap, promise: Promise) {
    val format = if (options.hasKey("format")) options.getString("format") else "wav"
    when (format?.lowercase()) {
      "aac" -> saveRecordingAac(filename, promise)
      else -> saveRecordingWav(filename, promise)
    }
  }

  private fun saveRecordingWav(filename: String, promise: Promise) {
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
            detectPitch(buffer.copyOfRange(0, read))

            if (!isPaused) {
                synchronized(this) {
                    for (i in 0 until read) {
                        sliceBuffer.add(buffer[i])

                        if (recordFullAudio) {
                          fullRecordingBuffer.add(buffer[i])
                        }
                    }

                    trimBuffer(sliceBuffer, maxSliceBufferSamples())
                    if (recordFullAudio) {
                      trimBuffer(fullRecordingBuffer, maxFullRecordingBufferSamples())
                    }
                }
            }
        }
      }
    }
  }

  private fun stopRecording() {
    isRecording = false
    audioRecord?.apply {
        stop()
        release()
    }
    audioRecord = null
    recordingThread?.interrupt()
    recordingThread = null
    isPaused = false
  }

  private external fun nativeAutoCorrelate(buffer: ShortArray, sampleRate: Int, minVolume: Double): Double

  private fun detectPitch(buffer: ShortArray){
    val pitch = nativeAutoCorrelate(buffer, sampleRate, minVolume)
    val params: WritableMap = Arguments.createMap()
    params.putDouble("pitch", pitch)
    reactApplicationContext.getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java).emit("onPitchDetected", params)
  }

  private fun maxSliceBufferSamples(): Int {
    return sampleRate * maxSliceDurationSeconds
  }

  private fun maxFullRecordingBufferSamples(): Int {
    return sampleRate * maxFullRecordingDurationSeconds
  }

  private fun trimBuffer(buffer: MutableList<Short>, maxSamples: Int) {
    val overflow = buffer.size - maxSamples
    if (overflow > 0) {
      buffer.subList(0, overflow).clear()
    }
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


  private fun saveRecordingAac(filename: String, promise: Promise) {
    synchronized(this) {
      if (fullRecordingBuffer.isEmpty()) {
        promise.reject("no_data", "No recording data available")
        return
      }
      try {
        val mime = "audio/mp4a-latm"
        val bitRate = 96000
        val channelCount = 1
        val sampleRateHz = sampleRate

        val codec = MediaCodec.createEncoderByType(mime)
        val format = MediaFormat.createAudioFormat(mime, sampleRateHz, channelCount)
        format.setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
        format.setInteger(MediaFormat.KEY_BIT_RATE, bitRate)

        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        codec.start()

        val outputFile = java.io.File(reactApplicationContext.filesDir, "$filename.m4a")
        val muxer = MediaMuxer(outputFile.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        var trackIndex = -1
        var muxerStarted = false

        val inputData = java.nio.ByteBuffer.allocateDirect(fullRecordingBuffer.size * 2)
        inputData.order(java.nio.ByteOrder.LITTLE_ENDIAN)
        for (s in fullRecordingBuffer) inputData.putShort(s)
        inputData.flip()

        var presentationTimeUs = 0L
        val bytesPerSample = 2
        val frameSamples = 1024 // AAC frame
        val frameBytes = frameSamples * bytesPerSample

        var eos = false
        val bufferInfo = MediaCodec.BufferInfo()
        while (!eos) {
          val inIndex = codec.dequeueInputBuffer(10000)
          if (inIndex >= 0) {
            val inBuf = codec.getInputBuffer(inIndex)!!
            inBuf.clear()
            val remaining = inputData.remaining()
            val toWrite = kotlin.math.min(remaining, frameBytes)
            if (toWrite > 0) {
              val temp = ByteArray(toWrite)
              inputData.get(temp)
              inBuf.put(temp)
              val ptsUs = presentationTimeUs
              presentationTimeUs += (1_000_000L * (toWrite / bytesPerSample)) / sampleRateHz
              codec.queueInputBuffer(inIndex, 0, toWrite, ptsUs, 0)
            } else {
              codec.queueInputBuffer(inIndex, 0, 0, presentationTimeUs, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
              eos = true
            }
          }

          var outIndex = codec.dequeueOutputBuffer(bufferInfo, 10000)
          while (outIndex >= 0) {
            val outBuf = codec.getOutputBuffer(outIndex)!!
            if (!muxerStarted) {
              val outFormat = codec.outputFormat
              trackIndex = muxer.addTrack(outFormat)
              muxer.start()
              muxerStarted = true
            }
            if (bufferInfo.size > 0 && muxerStarted) {
              outBuf.position(bufferInfo.offset)
              outBuf.limit(bufferInfo.offset + bufferInfo.size)
              muxer.writeSampleData(trackIndex, outBuf, bufferInfo)
            }
            codec.releaseOutputBuffer(outIndex, false)
            if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) break
            outIndex = codec.dequeueOutputBuffer(bufferInfo, 0)
          }
        }

        codec.stop(); codec.release()
        if (muxerStarted) muxer.stop()
        muxer.release()
        fullRecordingBuffer.clear()
        promise.resolve(outputFile.absolutePath)
      } catch (e: Exception) {
        promise.reject("aac_save_error", "Failed to save AAC recording", e)
      }
    }
  }
}
