import asyncio
from datetime import timedelta
import uuid
import time

from .depth import MAX_AGE_S


def viewer_token(settings):
    from livekit import api
    identity = "viewer-"+uuid.uuid4().hex
    token = (api.AccessToken(settings.livekit_key, settings.livekit_secret)
             .with_identity(identity).with_ttl(timedelta(minutes=10))
             .with_grants(api.VideoGrants(room_join=True, room=settings.room,
                                        can_subscribe=True, can_publish=False, can_publish_data=False)).to_jwt())
    return {"url": settings.livekit_public_url, "token": token, "room": settings.room,
            "identity": identity, "layout": "top-bottom", "track_name": "stereo",
            "publisher_identity": "stereo-camera"}


async def publish(runtime):
    from livekit import api, rtc
    settings = runtime.settings
    while True:
        room = rtc.Room()
        source = None
        try:
            runtime.video_status = "connecting"
            token = (api.AccessToken(settings.livekit_key, settings.livekit_secret)
                     .with_identity("stereo-camera").with_ttl(timedelta(hours=12))
                     .with_grants(api.VideoGrants(room_join=True, room=settings.room,
                                                can_publish=True, can_subscribe=False)).to_jwt())
            # Let the SDK own its negotiation timeout. Cancelling connect mid-FFI handshake
            # can invalidate the native callback handshake on some SDK versions.
            connecting = asyncio.create_task(room.connect(settings.livekit_url, token,
                                                          rtc.RoomOptions(connect_timeout=10)))
            try:
                await asyncio.shield(connecting)
            except asyncio.CancelledError:
                # Finish the native callback handshake before disconnecting its room.
                # Cancelling the Python waiter does not cancel native negotiation.
                await asyncio.gather(connecting, return_exceptions=True)
                raise
            source = rtc.VideoSource(settings.width, settings.height*2)
            track = rtc.LocalVideoTrack.create_video_track("stereo", source)
            options = rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_CAMERA, video_codec=rtc.VideoCodec.H264,
                       simulcast=False, degradation_preference=rtc.DegradationPreference.MAINTAIN_RESOLUTION.value,
                       video_encoding=rtc.VideoEncoding(max_framerate=settings.fps, max_bitrate=5_000_000))
            await room.local_participant.publish_track(track, options)
            runtime.video_status = "connected"
            sequence = -1
            while room.isconnected():
                frame = runtime.latest
                if (frame is not None and frame.frame_id != sequence and not runtime.camera_error
                        and time.monotonic() - frame.monotonic <= MAX_AGE_S):
                    sequence = frame.frame_id
                    rgb = frame.stereo_rgb()
                    source.capture_frame(rtc.VideoFrame(settings.width, settings.height*2,
                                         rtc.VideoBufferType.RGB24, rgb.tobytes()),
                                         timestamp_us=int(frame.monotonic*1_000_000))
                await asyncio.sleep(1/settings.fps)
        except asyncio.CancelledError:
            raise
        except Exception as error:
            runtime.video_status = "error: "+type(error).__name__
        finally:
            try:
                await room.disconnect()
            except Exception as error:
                runtime.video_status = "error: disconnect "+type(error).__name__
            finally:
                if source is not None:
                    await source.aclose()
                if runtime.video_status in ("connected", "connecting"):
                    runtime.video_status = "disconnected"
        await asyncio.sleep(2)
