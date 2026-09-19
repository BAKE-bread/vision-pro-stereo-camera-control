"""Generate original test video locally. Existing media is never overwritten."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
output = root / 'artifacts' / 'media'
output.mkdir(parents=True, exist_ok=True)
if any(output.glob('demo*')):
    raise SystemExit('Demo files already exist; keep them, or choose a different output directory. No files were changed.')
subprocess.run(['ffmpeg', '-n', '-f', 'lavfi', '-i', 'testsrc2=size=1280x720:rate=30',
                '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000', '-t', '12',
                '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-movflags', '+faststart',
                str(output/'demo.mp4')], check=True)
subprocess.run(['ffmpeg', '-n', '-i', str(output/'demo.mp4'), '-c:v', 'libx264', '-g', '60',
                '-sc_threshold', '0', '-c:a', 'aac', '-hls_time', '2', '-hls_playlist_type', 'vod',
                '-hls_segment_filename', str(output/'demo_%03d.ts'), str(output/'demo.m3u8')], check=True)
print(output)
