"""Executed when optional LiveKit dependencies are installed; no cloud required."""
import pytest
pytest.importorskip('livekit')
import jwt
from livekit import rtc
from server.config import Settings
from server.live_video import viewer_token
from server.camera import MockCamera


def test_subscriber_token_never_contains_publish_permission():
    settings = Settings(livekit_url='ws://localhost:7880', livekit_public_url='ws://camera.local:7880',
                        livekit_key='test', livekit_secret='a-test-secret-with-at-least-32-characters')
    session = viewer_token(settings)
    claims = jwt.decode(session['token'], settings.livekit_secret, algorithms=['HS256'])
    assert claims['video']['canSubscribe'] is True
    assert claims['video']['canPublish'] is False
    assert claims['exp']-claims['nbf'] == 600
    assert session['url'] == settings.livekit_public_url
    assert 'secret' not in session


def test_video_packing_passes_through_sdk_conversion():
    frame = MockCamera(160, 90).capture()
    sdk_frame = rtc.VideoFrame(160, 180, rtc.VideoBufferType.RGB24, frame.stereo_rgb().tobytes())
    converted = sdk_frame.convert(rtc.VideoBufferType.I420)
    assert converted.width == 160 and converted.height == 180



def publishing_settings():
    return Settings(width=160, height=90, livekit_url='ws://localhost:7880',
                    livekit_public_url='ws://localhost:7880', livekit_key='test',
                    livekit_secret='a-test-secret-with-at-least-32-characters')


@pytest.mark.parametrize('stale,disconnect_error', [(False, False), (True, False), (False, True)])
def test_publisher_reconnects_after_room_disconnect_and_disposes_sources(monkeypatch, stale, disconnect_error):
    import asyncio
    from dataclasses import replace
    from types import SimpleNamespace
    from server import live_video
    from server.runtime import Runtime
    runtime = Runtime(publishing_settings())
    frame = MockCamera(160, 90).capture()
    runtime.accept(replace(frame, monotonic=0) if stale else frame)
    rooms, sources, publications = [], [], []

    class Room:
        def __init__(self):
            self.connected = False
            self.closed = False
            self.local_participant = self
            rooms.append(self)
        async def connect(self, url, token, options):
            assert options.connect_timeout == 10
            self.connected = True
        async def publish_track(self, track, options):
            assert options.video_codec == rtc.VideoCodec.H264
            assert options.simulcast is False
            assert options.degradation_preference == rtc.DegradationPreference.MAINTAIN_RESOLUTION.value
            publications.append(track)
        def isconnected(self): return self.connected
        async def disconnect(self):
            self.closed = True
            if disconnect_error: raise RuntimeError('injected disconnect failure')

    class Source:
        def __init__(self, width, height):
            assert (width, height) == (160, 180)
            self.frames = []
            self.closed = False
            sources.append(self)
        def capture_frame(self, frame, *, timestamp_us):
            assert frame.width == 160 and frame.height == 180
            assert timestamp_us > 0
            self.frames.append(frame)
        async def aclose(self): self.closed = True

    async def sleep(delay):
        await asyncio.sleep(0)
        if delay == 2:
            if len(rooms) >= 2: raise asyncio.CancelledError()
        else:
            rooms[-1].connected = False

    monkeypatch.setattr(rtc, 'Room', Room)
    monkeypatch.setattr(rtc, 'VideoSource', Source)
    monkeypatch.setattr(rtc, 'LocalVideoTrack', SimpleNamespace(create_video_track=lambda name, source: source))
    monkeypatch.setattr(live_video, 'asyncio', SimpleNamespace(
        sleep=sleep, create_task=asyncio.create_task, shield=asyncio.shield,
        gather=asyncio.gather, CancelledError=asyncio.CancelledError))

    async def scenario():
        with pytest.raises(asyncio.CancelledError):
            await asyncio.wait_for(live_video.publish(runtime), 1)
    asyncio.run(scenario())
    assert len(rooms) == len(sources) == len(publications) == 2
    assert all(room.closed for room in rooms)
    assert all(source.closed for source in sources)
    assert all(len(source.frames) == (0 if stale else 1) for source in sources)


def test_cancelled_connect_finishes_native_handshake_before_disconnect(monkeypatch):
    import asyncio
    from server.live_video import publish
    from server.runtime import Runtime
    events = []

    async def scenario():
        entered, release = asyncio.Event(), asyncio.Event()
        class Room:
            async def connect(self, *args):
                entered.set()
                try: await release.wait()
                except asyncio.CancelledError:
                    events.append('connect-cancelled')
                    raise
                events.append('connect-finished')
            async def disconnect(self): events.append('disconnect')
        monkeypatch.setattr(rtc, 'Room', Room)
        task = asyncio.create_task(publish(Runtime(publishing_settings())))
        await entered.wait()
        task.cancel()
        await asyncio.sleep(.01)
        assert not task.done()
        assert not events
        release.set()
        with pytest.raises(asyncio.CancelledError): await task
    asyncio.run(scenario())
    assert events == ['connect-finished', 'disconnect']
