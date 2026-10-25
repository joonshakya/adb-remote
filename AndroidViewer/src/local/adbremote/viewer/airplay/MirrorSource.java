package local.adbremote.viewer.airplay;

/** Where mirrored video comes from: an iPhone (MirrorStream, AirPlay) or an Android phone (PhoneMirror). */
interface MirrorSource {
    /** The screen that shows the video; null while it isn't ready. */
    void setSink(MirrorStream.Sink sink);
}
