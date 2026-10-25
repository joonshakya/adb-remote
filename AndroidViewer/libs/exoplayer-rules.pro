# Proguard rules specific to the common module.

# Don't warn about checkerframework and Kotlin annotations
-dontwarn org.checkerframework.**
-dontwarn kotlin.annotations.jvm.**
-dontwarn javax.annotation.**

# From https://github.com/google/guava/wiki/UsingProGuardWithGuava
-dontwarn java.lang.ClassValue
-dontwarn java.lang.SafeVarargs
-dontwarn javax.lang.model.element.Modifier
-dontwarn sun.misc.Unsafe

# Don't warn about Guava's compile-only dependencies.
# These lines are needed for ProGuard but not R8.
-dontwarn com.google.errorprone.annotations.**
-dontwarn com.google.j2objc.annotations.**
-dontwarn org.codehaus.mojo.animal_sniffer.IgnoreJRERequirement

# Workaround for https://issuetracker.google.com/issues/112297269
# This is needed for ProGuard but not R8.
-keepclassmembernames class com.google.common.base.Function { *; }
# Proguard rules specific to the core module.

# Constructors accessed via reflection in DefaultRenderersFactory
-dontnote com.google.android.exoplayer2.ext.vp9.LibvpxVideoRenderer
-keepclassmembers class com.google.android.exoplayer2.ext.vp9.LibvpxVideoRenderer {
  <init>(long, android.os.Handler, com.google.android.exoplayer2.video.VideoRendererEventListener, int);
}
-dontnote com.google.android.exoplayer2.ext.av1.Libgav1VideoRenderer
-keepclassmembers class com.google.android.exoplayer2.ext.av1.Libgav1VideoRenderer {
  <init>(long, android.os.Handler, com.google.android.exoplayer2.video.VideoRendererEventListener, int);
}
-dontnote com.google.android.exoplayer2.ext.opus.LibopusAudioRenderer
-keepclassmembers class com.google.android.exoplayer2.ext.opus.LibopusAudioRenderer {
  <init>(android.os.Handler, com.google.android.exoplayer2.audio.AudioRendererEventListener, com.google.android.exoplayer2.audio.AudioSink);
}
-dontnote com.google.android.exoplayer2.ext.flac.LibflacAudioRenderer
-keepclassmembers class com.google.android.exoplayer2.ext.flac.LibflacAudioRenderer {
  <init>(android.os.Handler, com.google.android.exoplayer2.audio.AudioRendererEventListener, com.google.android.exoplayer2.audio.AudioSink);
}
-dontnote com.google.android.exoplayer2.ext.ffmpeg.FfmpegAudioRenderer
-keepclassmembers class com.google.android.exoplayer2.ext.ffmpeg.FfmpegAudioRenderer {
  <init>(android.os.Handler, com.google.android.exoplayer2.audio.AudioRendererEventListener, com.google.android.exoplayer2.audio.AudioSink);
}

# Constructors accessed via reflection in DefaultDownloaderFactory
-dontnote com.google.android.exoplayer2.source.dash.offline.DashDownloader
-keepclassmembers class com.google.android.exoplayer2.source.dash.offline.DashDownloader {
  <init>(com.google.android.exoplayer2.MediaItem, com.google.android.exoplayer2.upstream.cache.CacheDataSource$Factory, java.util.concurrent.Executor);
}
-dontnote com.google.android.exoplayer2.source.hls.offline.HlsDownloader
-keepclassmembers class com.google.android.exoplayer2.source.hls.offline.HlsDownloader {
  <init>(com.google.android.exoplayer2.MediaItem, com.google.android.exoplayer2.upstream.cache.CacheDataSource$Factory, java.util.concurrent.Executor);
}
-dontnote com.google.android.exoplayer2.source.smoothstreaming.offline.SsDownloader
-keepclassmembers class com.google.android.exoplayer2.source.smoothstreaming.offline.SsDownloader {
  <init>(com.google.android.exoplayer2.MediaItem, com.google.android.exoplayer2.upstream.cache.CacheDataSource$Factory, java.util.concurrent.Executor);
}

# Constructors accessed via reflection in DefaultMediaSourceFactory
-dontnote com.google.android.exoplayer2.source.dash.DashMediaSource$Factory
-keepclasseswithmembers class com.google.android.exoplayer2.source.dash.DashMediaSource$Factory {
  <init>(com.google.android.exoplayer2.upstream.DataSource$Factory);
}
-dontnote com.google.android.exoplayer2.source.hls.HlsMediaSource$Factory
-keepclasseswithmembers class com.google.android.exoplayer2.source.hls.HlsMediaSource$Factory {
  <init>(com.google.android.exoplayer2.upstream.DataSource$Factory);
}
-dontnote com.google.android.exoplayer2.source.smoothstreaming.SsMediaSource$Factory
-keepclasseswithmembers class com.google.android.exoplayer2.source.smoothstreaming.SsMediaSource$Factory {
  <init>(com.google.android.exoplayer2.upstream.DataSource$Factory);
}
-dontnote com.google.android.exoplayer2.source.rtsp.RtspMediaSource$Factory
-keepclasseswithmembers class com.google.android.exoplayer2.source.rtsp.RtspMediaSource$Factory {
  <init>();
}
# Proguard rules specific to the DataSource module.

# Constant folding for resource integers may mean that a resource passed to this method appears to be unused. Keep the method to prevent this from happening.
-keepclassmembers class com.google.android.exoplayer2.upstream.RawResourceDataSource {
  public static android.net.Uri buildRawResourceUri(int);
}

# Constructors accessed via reflection in DefaultDataSource
-dontnote com.google.android.exoplayer2.ext.rtmp.RtmpDataSource
-keepclassmembers class com.google.android.exoplayer2.ext.rtmp.RtmpDataSource {
  <init>();
}
# Proguard rules specific to the extractor module.

# Methods accessed via reflection in DefaultExtractorsFactory
-dontnote com.google.android.exoplayer2.ext.flac.FlacExtractor
-keepclassmembers class com.google.android.exoplayer2.ext.flac.FlacExtractor {
  <init>(int);
}
-dontnote com.google.android.exoplayer2.ext.flac.FlacLibrary
-keepclassmembers class com.google.android.exoplayer2.ext.flac.FlacLibrary {
  public static boolean isAvailable();
}

# Don't warn about checkerframework and Kotlin annotations
-dontwarn org.checkerframework.**
-dontwarn kotlin.annotations.jvm.**
-dontwarn javax.annotation.**
