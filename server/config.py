from dataclasses import dataclass
import os


@dataclass
class Settings:
    source: str = "mock"
    width: int = 640
    height: int = 360
    fps: int = 20
    api_token: str = ""
    livekit_url: str = ""
    livekit_public_url: str = ""
    livekit_key: str = ""
    livekit_secret: str = ""
    room: str = "stereo-studio"
    calibration: str = ""
    enable_hardware: bool = False

    @classmethod
    def from_env(cls):
        return cls(source=os.getenv("STEREO_SOURCE", "mock"),
                   api_token=os.getenv("STEREO_API_TOKEN", ""),
                   livekit_url=os.getenv("LIVEKIT_URL", ""),
                   livekit_public_url=os.getenv("LIVEKIT_PUBLIC_URL", ""),
                   livekit_key=os.getenv("LIVEKIT_API_KEY", ""),
                   livekit_secret=os.getenv("LIVEKIT_API_SECRET", ""),
                   calibration=os.getenv("GIMBAL_CALIBRATION", ""),
                   enable_hardware=os.getenv("ENABLE_HARDWARE", "") == "1")

    def validate(self):
        if self.width < 2 or self.height < 2 or self.width % 2 or self.height % 2 or self.fps <= 0:
            raise ValueError("Video dimensions must be positive even numbers; fps must be positive")
        if self.source not in ("mock", "zed"):
            raise ValueError("STEREO_SOURCE must be mock or zed")
        if self.source == "zed" and not self.enable_hardware:
            raise ValueError("ZED requires ENABLE_HARDWARE=1")
        if self.calibration and not self.enable_hardware:
            raise ValueError("Gimbal requires ENABLE_HARDWARE=1")
        if self.calibration and self.source != "zed":
            raise ValueError("Physical gimbal requires the ZED source; mock never actuates hardware")
        if self.livekit_url and not all((self.livekit_key, self.livekit_secret, self.livekit_public_url)):
            raise ValueError("Set LIVEKIT_API_KEY, LIVEKIT_API_SECRET and LIVEKIT_PUBLIC_URL")
