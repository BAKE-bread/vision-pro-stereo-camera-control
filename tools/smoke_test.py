"""Real HTTP, WebSocket and optional LiveKit loopback integration test."""
import argparse
import asyncio
import json
from pathlib import Path
import time
import httpx
import numpy as np
import websockets


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--url', default='http://127.0.0.1:8765')
    parser.add_argument('--livekit', action='store_true')
    parser.add_argument('--output', type=Path, help='Write the report to a separate path')
    args = parser.parse_args()
    report = {}
    async with httpx.AsyncClient(base_url=args.url, timeout=10) as client:
        cap = (await client.get('/api/capabilities')).raise_for_status().json()
        snap = (await client.get('/api/snapshot')).raise_for_status().json()
        point = (await client.post('/api/depth/measure', json={'frame_id': snap['frame_id'], 'u': .5, 'v': .5})).raise_for_status().json()
        assert point['valid']
        report['snapshot'] = {'frame_id': snap['frame_id'], 'depth_cells': len(snap['depth_m']), 'center_range_m': point['range_m']}
        async with websockets.connect(args.url.replace('http', 'ws', 1)+'/api/control') as ws:
            await ws.send(json.dumps({'token': ''}))
            hello = json.loads(await ws.recv())
            assert hello['type'] == 'lease'
            for sequence in range(8):
                await ws.send(json.dumps({'sequence': sequence, 'yaw_deg': 25, 'pitch_deg': 5}))
                ack = json.loads(await ws.recv())
                assert ack['type'] == 'ack'
                await asyncio.sleep(.1)
            assert ack['yaw_deg'] > 10
            report['control'] = {'yaw_deg': ack['yaw_deg'], 'pitch_deg': ack['pitch_deg']}
        await asyncio.sleep(.1)
        state = (await client.get('/api/status')).raise_for_status().json()
        assert not state['control']['active']
        # Let a fresh controller time out without a disconnect to verify watchdog in the running loop.
        async with websockets.connect(args.url.replace('http', 'ws', 1)+'/api/control') as ws:
            await ws.send(json.dumps({'token': ''})); await ws.recv()
            await asyncio.sleep(1.3)
            assert not (await client.get('/api/status')).json()['control']['active']
        report['disconnect_release'] = True
        report['watchdog_release'] = True
        mp4 = await client.get('/media/demo.mp4', headers={'Range': 'bytes=0-1023'})
        assert mp4.status_code == 206 and len(mp4.content) == 1024
        hls = (await client.get('/media/demo.m3u8')).raise_for_status().text
        assert '#EXTM3U' in hls and '#EXT-X-ENDLIST' in hls
        report['mp4_range_and_hls'] = True
        if args.livekit:
            from livekit import rtc
            session = (await client.post('/api/session')).raise_for_status().json()
            room = rtc.Room()
            done = asyncio.Event()
            frames = []
            consumers = []

            async def consume(track):
                stream = rtc.VideoStream(track)
                try:
                    async for event in stream:
                        rgb = event.frame.convert(rtc.VideoBufferType.RGB24)
                        pixels = np.frombuffer(rgb.data, np.uint8).reshape(rgb.height, rgb.width, 3)
                        frames.append((rgb.width, rgb.height, float(np.mean(np.abs(pixels[:rgb.height//2].astype(float)-pixels[rgb.height//2:])))))
                        if len(frames) >= 10:
                            done.set(); break
                finally:
                    await stream.aclose()

            @room.on('track_subscribed')
            def on_track(track, publication, participant):
                if track.kind == rtc.TrackKind.KIND_VIDEO:
                    consumers.append(asyncio.create_task(consume(track)))

            start = time.monotonic()
            try:
                await room.connect(session['url'], session['token'])
                await asyncio.wait_for(done.wait(), 30)
                assert all(w == cap['eye_width'] and h == cap['eye_height']*2 and difference > .1 for w, h, difference in frames)
                report['livekit'] = {'decoded_frames': len(frames), 'width': frames[0][0], 'height': frames[0][1],
                                     'stereo_difference': frames[-1][2], 'subscription_test_seconds': round(time.monotonic()-start, 2)}
            finally:
                for task in consumers:
                    task.cancel()
                await asyncio.gather(*consumers, return_exceptions=True)
                await room.disconnect()
    output = args.output or Path(__file__).resolve().parents[1]/'artifacts'/'smoke-report.json'
    output.parent.mkdir(exist_ok=True)
    output.write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    asyncio.run(main())
