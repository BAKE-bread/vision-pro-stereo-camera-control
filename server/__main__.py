import argparse
import uvicorn
from .app import create_app
from .config import Settings

parser = argparse.ArgumentParser()
parser.add_argument("--host", default="127.0.0.1")
parser.add_argument("--port", type=int, default=8765)
parser.add_argument("--access-log", action="store_true", help="Log each snapshot/HTTP request")
args = parser.parse_args()
settings = Settings.from_env()
if args.host not in ("127.0.0.1", "localhost", "::1") and not settings.api_token:
    parser.error("LAN binding requires STEREO_API_TOKEN")
uvicorn.run(create_app(settings), host=args.host, port=args.port, access_log=args.access_log)
