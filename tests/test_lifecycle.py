"""Fault injection for shutdown and camera SDK contracts; no real hardware."""
import asyncio
from dataclasses import replace
import threading
import time
from types import SimpleNamespace

import numpy as np
import pytest

from server.app import create_app
from server.camera import MockCamera, ZEDCamera
from server.config import Settings
from server.devices import DeviceWorker
from server.runtime import Runtime
from server.gimbal import DynamixelGimbal


@pytest.mark.parametrize('method', ['capture', 'move'])
def test_cancelled_operation_finishes_before_close_on_same_thread(method):
    entered, release = threading.Event(), threading.Event()
    events = []

    class Device:
        def __init__(self):
            events.append(('open', threading.get_ident()))

        def operation(self):
            events.append(('begin', threading.get_ident()))
            entered.set()
            assert release.wait(3), 'test did not release blocking IO'
            events.append(('end', threading.get_ident()))

        capture = move = operation

        def close(self):
            events.append(('close', threading.get_ident()))

    async def scenario():
        worker = DeviceWorker(Device, 'test-device')
        await worker.start()
        operation = asyncio.create_task(worker.call(method))
        assert await asyncio.to_thread(entered.wait, 2)
        operation.cancel()
        with pytest.raises(asyncio.CancelledError):
            await operation
        closing = asyncio.create_task(worker.close())
        await asyncio.sleep(.03)
        assert not closing.done()
        assert not any(e[0] == 'close' for e in events)
        release.set()
        await closing
        await worker.close()  # Idempotent.
        with pytest.raises(RuntimeError, match='closing'):
            await worker.call(method)

    try:
        asyncio.run(scenario())
    finally:
        release.set()
    assert [e[0] for e in events] == ['open', 'begin', 'end', 'close']
    assert len({e[1] for e in events}) == 1


def test_lifespan_closes_both_devices_after_blocking_operations():
    camera_entered, driver_entered = threading.Event(), threading.Event()
    release = threading.Event()
    events = []

    class Camera(MockCamera):
        def capture(self, *args):
            if self.sequence:
                camera_entered.set()
                assert release.wait(3)
                events.append('capture-finished')
            return super().capture(*args)

        def close(self):
            events.append('camera-closed')

    class Driver:
        def configuration(self):
            return (0, 0), {'yaw': (-10, 10), 'pitch': (-5, 5)}

        def move(self, *args):
            driver_entered.set()
            assert release.wait(3)
            events.append('move-finished')

        def close(self):
            events.append('driver-closed')

    async def scenario():
        app = create_app(Settings(width=160, height=90), camera_factory=lambda: Camera(160, 90), gimbal_factory=Driver)
        context = app.router.lifespan_context(app)
        await context.__aenter__()
        assert await asyncio.to_thread(camera_entered.wait, 2)
        assert await asyncio.to_thread(driver_entered.wait, 2)
        closing = asyncio.create_task(context.__aexit__(None, None, None))
        await asyncio.sleep(.03)
        assert not closing.done()
        assert not events
        release.set()
        await closing

    try:
        asyncio.run(scenario())
    finally:
        release.set()
    assert events.index('capture-finished') < events.index('camera-closed')
    assert events.index('move-finished') < events.index('driver-closed')


def test_startup_failure_still_closes_camera():
    closed = []

    class Camera(MockCamera):
        def capture(self, *args):
            raise RuntimeError('startup capture failure')

        def close(self):
            closed.append(True)

    async def scenario():
        app = create_app(Settings(width=160, height=90), camera_factory=lambda: Camera(160, 90))
        with pytest.raises(RuntimeError, match='startup capture'):
            async with app.router.lifespan_context(app):
                pytest.fail('startup should fail')

    asyncio.run(scenario())
    assert closed == [True]


def fake_zed(failure=None):
    """Leave old arrays intact when retrieve fails, as an SDK may do."""
    camera = object.__new__(ZEDCamera)
    camera.width, camera.height = 8, 4
    camera.sequence = 7
    camera.last_timestamp_ms = None
    camera.runtime = camera.resolution = None
    camera.intrinsics = (6., 6., 3.5, 1.5)
    arrays = [np.zeros((4, 8, 4), np.uint8), np.zeros((4, 8, 4), np.uint8), np.full((4, 8), 2., np.float32)]
    camera.left, camera.right, camera.depth = [SimpleNamespace(get_data=lambda a=a: a) for a in arrays]
    camera.sl = SimpleNamespace(ERROR_CODE=SimpleNamespace(SUCCESS=0), VIEW=SimpleNamespace(LEFT='left', RIGHT='right'),
                                MEM=SimpleNamespace(CPU=0), MEASURE=SimpleNamespace(DEPTH='depth'), TIME_REFERENCE=SimpleNamespace(IMAGE=0))
    camera.zed = SimpleNamespace(
        grab=lambda _: 1 if failure == 'grab' else 0,
        retrieve_image=lambda buffer, view, *args: 1 if view == failure else 0,
        retrieve_measure=lambda *args: 1 if failure == 'depth' else 0,
        get_timestamp=lambda _: SimpleNamespace(get_milliseconds=lambda: 123456))
    return camera, arrays


@pytest.mark.parametrize('stage', ['grab', 'left', 'right', 'depth'])
def test_failed_zed_extraction_never_relabels_old_buffers(stage):
    camera, arrays = fake_zed(stage)
    with pytest.raises(RuntimeError, match='ZED'):
        camera.capture()
    assert camera.sequence == 7
    assert np.all(arrays[2] == 2.)


@pytest.mark.parametrize('field,value', [('left', np.zeros((4, 7, 4), np.uint8)),
                                        ('right', np.zeros((4, 8, 4), np.float32)),
                                        ('depth', np.zeros((4, 8), np.uint16)),
                                        ('depth', np.zeros((4, 7), np.float32))])
def test_zed_rejects_wrong_shape_or_type(field, value):
    camera, _ = fake_zed()
    setattr(camera, field, SimpleNamespace(get_data=lambda: value))
    with pytest.raises(RuntimeError, match='shape or type'):
        camera.capture()
    assert camera.sequence == 7


def test_successful_zed_pair_owns_depth_and_advances_once():
    camera, arrays = fake_zed()
    frame = camera.capture()
    arrays[2][:] = 9
    assert frame.frame_id == 8
    assert frame.left.shape == frame.right.shape == (4, 8, 3)
    assert np.all(frame.depth_m == 2)


def test_measurement_history_does_not_retain_rgb_and_prunes_expired():
    runtime = Runtime(Settings())
    frame = MockCamera(160, 90).capture()
    runtime.accept(frame)
    saved = runtime.frames[frame.frame_id]
    assert not hasattr(saved, 'left') and not hasattr(saved, 'right')
    assert saved.depth_m is frame.depth_m
    runtime.accept(replace(frame, frame_id=2, monotonic=frame.monotonic + 1))
    assert list(runtime.frames) == [2]


def test_gimbal_close_attempts_both_axes_and_closes_port_after_failure():
    driver = object.__new__(DynamixelGimbal)
    actions = []
    driver.success = 0
    driver.enabled = [1, 2]
    driver.port = SimpleNamespace(closePort=lambda: actions.append('port-closed'))

    def disable(port, servo_id, register, value):
        actions.append(servo_id)
        return (1 if servo_id == 1 else 0, 0)

    driver.packet = SimpleNamespace(write1ByteTxRx=disable)
    with pytest.raises(RuntimeError, match='communication failure'):
        driver.close()
    assert actions == [1, 2, 'port-closed']


def test_invalid_second_axis_does_not_write_first_axis():
    driver = object.__new__(DynamixelGimbal)
    writes = []
    driver.axes = [dict(id=n, center_tick=2048, sign=1, ticks_per_degree=10, min_tick=0, max_tick=4095) for n in (1, 2)]
    driver.port = None
    driver.success = 0
    driver.packet = SimpleNamespace(write4ByteTxRx=lambda *args: (writes.append(args) or 0, 0))
    with pytest.raises(ValueError, match='invalid angle'):
        driver.move(10, float('nan'))
    assert not writes


@pytest.mark.parametrize('settings', [Settings(width=0), Settings(height=91), Settings(fps=0)])
def test_invalid_video_configuration_rejected_before_startup(settings):
    with pytest.raises(ValueError, match='dimensions'):
        settings.validate()


@pytest.mark.parametrize('timestamp', [0, 123456, 123455])
def test_zed_repeated_or_invalid_timestamp_never_becomes_a_new_frame(timestamp):
    camera, _ = fake_zed()
    camera.last_timestamp_ms = 123456
    camera.zed.get_timestamp = lambda _: SimpleNamespace(get_milliseconds=lambda: timestamp)
    with pytest.raises(RuntimeError, match='timestamp'):
        camera.capture()
    assert camera.sequence == 7


def test_zed_channel_order_invalid_depth_and_buffer_ownership():
    camera, arrays = fake_zed()
    arrays[0][:] = [11, 22, 33, 255]
    arrays[1][:] = [44, 55, 66, 255]
    arrays[2][0, :4] = [float('inf'), float('nan'), .1, 21]
    frame = camera.capture()
    assert frame.left[0, 0].tolist() == [33, 22, 11]
    assert frame.right[0, 0].tolist() == [66, 55, 44]
    assert np.isnan(frame.depth_m[0, :4]).all()
    arrays[0][:] = 0
    arrays[1][:] = 0
    assert frame.left[0, 0].tolist() == [33, 22, 11]
    assert frame.right[0, 0].tolist() == [66, 55, 44]


def test_shutdown_does_not_wait_for_camera_before_closing_gimbal():
    entered, release, driver_closed = threading.Event(), threading.Event(), threading.Event()
    class Camera(MockCamera):
        def capture(self, *args):
            if self.sequence:
                entered.set()
                assert release.wait(3)
            return super().capture(*args)
    class Driver:
        def configuration(self): return (0, 0), {'yaw': (-10, 10), 'pitch': (-5, 5)}
        def move(self, *args): pass
        def close(self): driver_closed.set()
    async def scenario():
        app = create_app(Settings(width=160, height=90), camera_factory=lambda: Camera(160, 90), gimbal_factory=Driver)
        context = app.router.lifespan_context(app)
        await context.__aenter__()
        assert await asyncio.to_thread(entered.wait, 2)
        closing = asyncio.create_task(context.__aexit__(None, None, None))
        assert await asyncio.to_thread(driver_closed.wait, 1)
        assert not closing.done()
        release.set()
        await closing
    try: asyncio.run(scenario())
    finally: release.set()


def test_camera_failure_never_constructs_gimbal():
    constructed = []
    class Camera(MockCamera):
        def capture(self, *args): raise RuntimeError('camera failed')
    async def scenario():
        app = create_app(Settings(width=160, height=90), camera_factory=lambda: Camera(160, 90),
                         gimbal_factory=lambda: constructed.append(True))
        with pytest.raises(RuntimeError, match='camera failed'):
            async with app.router.lifespan_context(app): pass
    asyncio.run(scenario())
    assert not constructed
