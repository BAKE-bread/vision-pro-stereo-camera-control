import asyncio
from collections import OrderedDict
import time

from .control import Controller
from .depth import MAX_AGE_S


class Runtime:
    def __init__(self, settings):
        self.settings = settings
        self.controller = Controller()
        self.latest = None
        self.frames = OrderedDict()
        self.camera_error = None
        self.control_error = None
        self.video_status = "disabled"
        self.stopping = False

    def accept(self, frame):
        self.latest = frame
        # History retains depth and intrinsics only, never both RGB images.
        self.frames[frame.frame_id] = frame.measurement_frame()
        while self.frames:
            oldest = next(iter(self.frames.values()))
            if len(self.frames) <= 30 and frame.monotonic - oldest.monotonic <= MAX_AGE_S:
                break
            self.frames.popitem(last=False)
        self.camera_error = None

    def release_control(self):
        if self.controller.lease:
            self.controller.release(self.controller.lease)

    async def capture(self, camera):
        while not self.stopping:
            start = time.monotonic()
            try:
                frame = await camera.call("capture", self.controller.yaw, self.controller.pitch)
                if not self.stopping:
                    self.accept(frame)
            except Exception as error:
                self.camera_error = str(error)
                self.release_control()
            await asyncio.sleep(max(.001, 1/self.settings.fps-(time.monotonic()-start)))

    async def control_loop(self):
        while not self.stopping:
            try:
                if self.camera_error or self.latest is None or time.monotonic()-self.latest.monotonic > MAX_AGE_S:
                    self.release_control()
                self.controller.tick()
                if self.controller.driver:
                    await self.controller.driver.call("move", self.controller.yaw, self.controller.pitch)
            except Exception as error:
                self.control_error = "gimbal: "+str(error)
                self.release_control()
                return
            await asyncio.sleep(.02)
