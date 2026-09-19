import asyncio
import json
from contextlib import asynccontextmanager
from pathlib import Path
import secrets
from urllib.parse import urlparse

from fastapi import FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, ConfigDict, Field, ValidationError

from .camera import MockCamera, ZEDCamera
from .config import Settings
from .control import ControlError
from .devices import DeviceWorker
from .runtime import Runtime
from .depth import ensure_fresh, measure, snapshot


class Pose(BaseModel):
    model_config = ConfigDict(allow_inf_nan=False)
    sequence: int = Field(ge=0, strict=True)
    yaw_deg: float
    pitch_deg: float


class Point(BaseModel):
    model_config = ConfigDict(allow_inf_nan=False)
    frame_id: int = Field(ge=1)
    u: float = Field(ge=0, le=1)
    v: float = Field(ge=0, le=1)


async def receive_control_json(websocket):
    message = await websocket.receive()
    if message['type'] == 'websocket.disconnect':
        raise WebSocketDisconnect(message.get('code', 1000))
    payload = message.get('text')
    if payload is None:
        payload = message.get('bytes')
    if payload is None or len(payload) > 4096:
        raise ValueError('invalid_control_message')
    value = json.loads(payload)
    if not isinstance(value, dict):
        raise ValueError('control_message_must_be_object')
    return value


def create_app(settings=None, *, camera_factory=None, gimbal_factory=None):
    settings = settings or Settings.from_env()
    settings.validate()
    runtime = Runtime(settings)

    @asynccontextmanager
    async def lifespan(app):
        factory = camera_factory or (lambda: (ZEDCamera if settings.source == "zed" else MockCamera)(settings.width, settings.height))
        camera = DeviceWorker(factory, "stereo-camera")
        driver = None
        tasks = []
        runtime.stopping = False
        try:
            await camera.start()
            # Establish camera readiness before a real actuator can be armed.
            runtime.accept(await camera.call("capture", runtime.controller.yaw, runtime.controller.pitch))
            if settings.calibration or gimbal_factory:
                from .gimbal import DynamixelGimbal
                driver = DeviceWorker(gimbal_factory or (lambda: DynamixelGimbal(settings.calibration)), "stereo-gimbal")
                await driver.start()
                initial, bounds = await driver.call("configuration")
                c = runtime.controller
                c.driver = driver
                c.yaw = c.target_yaw = initial[0]
                c.pitch = c.target_pitch = initial[1]
                c.bounds = bounds
            tasks = [asyncio.create_task(runtime.capture(camera)), asyncio.create_task(runtime.control_loop())]
            if settings.livekit_url:
                from .live_video import publish
                runtime.video_status = "connecting"
                tasks.append(asyncio.create_task(publish(runtime)))
            yield
        finally:
            runtime.stopping = True
            runtime.release_control()
            for task in tasks:
                task.cancel()
            # Queue each close on its own device owner immediately. A stalled
            # camera or media handshake must not delay releasing servo torque.
            closing = [camera.close()]
            if driver:
                closing.append(driver.close())
            results = await asyncio.gather(*tasks, *closing, return_exceptions=True)
            runtime.controller.driver = None
            for result in results[len(tasks):]:
                if isinstance(result, BaseException):
                    raise result

    app = FastAPI(title="Stereo Studio", version="1.0.0", lifespan=lifespan)
    app.state.runtime = runtime

    def authorized(token):
        return not settings.api_token or secrets.compare_digest(token, settings.api_token)

    @app.middleware("http")
    async def authentication(request: Request, call_next):
        if request.url.path.startswith("/api/") and not authorized(request.headers.get("authorization", "").removeprefix("Bearer ")):
            from fastapi.responses import JSONResponse
            return JSONResponse({"detail": "unauthorized"}, status_code=401)
        response = await call_next(request)
        response.headers["Cache-Control"] = "no-store"
        return response

    @app.get("/api/capabilities")
    async def capabilities():
        return {"protocol": 1, "source": settings.source, "stereo_layout": "top-bottom",
                "eye_width": settings.width, "eye_height": settings.height,
                "depth": True, "head_control": settings.source == "mock" or bool(settings.calibration),
                "livekit": bool(settings.livekit_url), "video_status": runtime.video_status}

    @app.get("/api/status")
    async def status():
        return {"source": settings.source, "video_status": runtime.video_status,
                "camera_error": runtime.camera_error, "control": runtime.controller.state(),
                "control_error": runtime.control_error,
                "frame_id": runtime.latest.frame_id if runtime.latest else None}

    @app.post("/api/session")
    async def session():
        if not settings.livekit_url:
            raise HTTPException(503, "LiveKit is not configured; use the snapshot demo or configure a LiveKit server")
        from .live_video import viewer_token
        return viewer_token(settings)

    @app.get("/api/snapshot")
    async def get_snapshot():
        if runtime.stopping or runtime.camera_error:
            raise HTTPException(503, "camera_unavailable")
        try:
            return await asyncio.to_thread(snapshot, runtime.latest)
        except ValueError as error:
            raise HTTPException(409, str(error)) from error

    @app.post("/api/depth/measure")
    async def get_measure(point: Point):
        if runtime.stopping or runtime.camera_error:
            raise HTTPException(503, "camera_unavailable")
        frame = runtime.frames.get(point.frame_id)
        if frame is None:
            raise HTTPException(409, "frame_expired")
        try:
            return measure(frame, point.u, point.v)
        except ValueError as error:
            raise HTTPException(409, str(error)) from error

    @app.websocket("/api/control")
    async def control(websocket: WebSocket):
        # Browser tokens travel in the first message, never in URLs or access logs.
        origin = websocket.headers.get("origin")
        if origin and urlparse(origin).netloc != websocket.headers.get("host"):
            await websocket.close(1008)
            return
        await websocket.accept()
        lease = None
        try:
            hello = await asyncio.wait_for(receive_control_json(websocket), 3)
            if not authorized(str(hello.get("token", ""))):
                await websocket.close(4401)
                return
            if settings.source != "mock" and not settings.calibration:
                await websocket.send_json({"error": "gimbal_not_configured"})
                await websocket.close(4409)
                return
            if runtime.stopping or runtime.camera_error or runtime.control_error:
                raise ControlError("camera_unavailable")
            ensure_fresh(runtime.latest)
            acquired = runtime.controller.acquire()
            lease = acquired["lease_id"]
            await websocket.send_json({"type": "lease", **acquired})
            while True:
                data = await asyncio.wait_for(receive_control_json(websocket), 1.2)
                if data.get("type") == "release":
                    break
                pose = Pose.model_validate(data)
                if runtime.stopping or runtime.camera_error or runtime.control_error:
                    raise ControlError("camera_unavailable")
                ensure_fresh(runtime.latest)
                state = runtime.controller.command(lease, pose.sequence, pose.yaw_deg, pose.pitch_deg)
                await websocket.send_json({"type": "ack", "sequence": pose.sequence, **state})
        except (ControlError, ValidationError, ValueError) as error:
            try:
                await websocket.send_json({"error": str(error) if isinstance(error, ControlError) else "invalid_or_stale_data"})
            except WebSocketDisconnect:
                pass
        except (WebSocketDisconnect, asyncio.TimeoutError):
            pass
        finally:
            if lease:
                runtime.controller.release(lease)
            try:
                await websocket.close()
            except RuntimeError:
                pass

    web = Path(__file__).resolve().parent.parent / "web"
    @app.get("/")
    async def index():
        return FileResponse(web / "index.html")
    app.mount("/web", StaticFiles(directory=web), name="web")
    media = Path(__file__).resolve().parent.parent / "artifacts" / "media"
    if media.exists():
        app.mount("/media", StaticFiles(directory=media), name="media")
    return app
