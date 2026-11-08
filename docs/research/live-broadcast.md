# Live broadcast from Studio iOS (spec 18.7)

Status: research only. Provider decision D3 is open, so `LiveBroadcasting` has only `UnavailableLiveBroadcaster`.

## What the OS gives us

| Need | API | Notes |
|---|---|---|
| Camera and mic | `AVCaptureSession`, `AVCaptureMultiCamSession` | External mics through `AVAudioSession` routes |
| Hardware encode | `VTCompressionSession` | H.264 for RTMP; HEVC is possible over SRT |
| Screen broadcast | ReplayKit Broadcast Upload Extension | Separate process with a tight memory limit (about 50 MB), so ingest must be small |
| Background | Foreground capture only; screen broadcast runs in its extension | Camera capture stops when backgrounded, except with multitasking camera access on iPad |

## Ingest transport

| | RTMP | SRT |
|---|---|---|
| Provider support | Universal, including Bunny preview and self-hosted | Self-hosted; check Bunny |
| Weak networks | TCP, stalls under loss | Retransmit over UDP, better on mobile |
| Codec | H.264 + AAC | Codec agnostic |
| Client library | HaishinKit (BSD-3) covers RTMP and SRT | SRT needs libsrt (MPL-2.0) |

No Apple framework speaks RTMP or SRT, so a client library or a small custom muxer is needed either way.

## Recommendation

Adopt HaishinKit behind `LiveBroadcasting` once D3 is settled, RTMP first and SRT next if the provider accepts it.
Adaptive bitrate comes from reacting to send-buffer growth by lowering `AverageBitRate` on the compression session,
surfaced through `health()`. Check the $500/month infrastructure cap when choosing the provider.

## Needed before building

D3 decision, an ingest URL and stream-key API (Epic 9), signing with the camera, microphone and broadcast-extension
capabilities, and a real device (the simulator has no camera).
