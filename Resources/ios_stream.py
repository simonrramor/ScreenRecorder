#!/usr/bin/env python3
"""
Persistent iOS screen streaming helper (compatibility mode).

Streams pymobiledevice3 screenshots:
    [4 bytes big-endian length][PNG data] repeated

Live mirroring uses macOS's native iOS screen-capture device instead;
this script is only the fallback when that path is unavailable.
"""

import sys
import struct
import time
import json
import asyncio
import urllib.request
import io


def get_tunnel_info(udid=None):
    """Get tunnel address/port from tunneld HTTP API."""
    try:
        resp = urllib.request.urlopen('http://127.0.0.1:49151/', timeout=3)
        tunnels = json.loads(resp.read())
        if udid:
            # Try with and without dashes
            udid_nodash = udid.replace('-', '')
            for dev_udid, tunnel_list in tunnels.items():
                if dev_udid == udid or dev_udid.replace('-', '') == udid_nodash:
                    if tunnel_list:
                        return tunnel_list[0], dev_udid
        for dev_udid, tunnel_list in tunnels.items():
            if tunnel_list:
                return tunnel_list[0], dev_udid
    except Exception as e:
        sys.stderr.write(f"Tunneld query failed: {e}\n")
    return None, None


def downscale_png(png_data):
    """Downscale PNG data while preserving its display profile."""
    try:
        from PIL import Image
        img = Image.open(io.BytesIO(png_data))
        icc_profile = img.info.get('icc_profile')

        # iOS screenshots arrive as color-profiled PNGs. Keeping them as PNG
        # avoids the contrast/saturation shifts we saw when transcoding to JPEG.
        new_w = max(2, img.width // 2)
        new_h = max(2, img.height // 2)

        try:
            resample = Image.Resampling.BILINEAR
        except AttributeError:
            resample = Image.BILINEAR

        img = img.resize((new_w, new_h), resample)
        buf = io.BytesIO()
        save_args = {
            'format': 'PNG',
            'optimize': False,
            'compress_level': 1,
        }
        if icc_profile:
            save_args['icc_profile'] = icc_profile

        img.save(buf, **save_args)
        return buf.getvalue()
    except Exception:
        return png_data


async def stream(udid=None):
    tunnel_info, resolved_udid = get_tunnel_info(udid)
    if not tunnel_info:
        sys.stderr.write("ERROR: No tunnel available. Is tunneld running?\n")
        sys.stderr.flush()
        sys.exit(1)

    tunnel_addr = tunnel_info['tunnel-address']
    tunnel_port = tunnel_info['tunnel-port']
    sys.stderr.write(f"Connecting to {resolved_udid} via [{tunnel_addr}]:{tunnel_port}\n")
    sys.stderr.flush()

    from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService
    from pymobiledevice3.services.dvt.dvt_secure_socket_proxy import DvtSecureSocketProxyService
    from pymobiledevice3.services.dvt.instruments.screenshot import Screenshot

    rsd = RemoteServiceDiscoveryService((tunnel_addr, tunnel_port))
    await rsd.connect()
    sys.stderr.write(f"RSD connected: {rsd.udid}\n")
    sys.stderr.flush()

    stdout = sys.stdout.buffer

    with DvtSecureSocketProxyService(lockdown=rsd) as dvt:
        screenshot = Screenshot(dvt)
        sys.stderr.write("STREAMING\n")
        sys.stderr.flush()

        frame_count = 0
        start_time = time.time()

        while True:
            try:
                png_data = screenshot.get_screenshot()
                # Downscale the profiled PNG for faster transfer.
                frame_data = downscale_png(png_data)
                length = len(frame_data)
                stdout.write(struct.pack('>I', length))
                stdout.write(frame_data)
                stdout.flush()

                frame_count += 1
                if frame_count % 10 == 0:
                    elapsed = time.time() - start_time
                    fps = frame_count / elapsed
                    sys.stderr.write(f"fps={fps:.1f} frames={frame_count}\n")
                    sys.stderr.flush()

            except BrokenPipeError:
                break
            except Exception as e:
                sys.stderr.write(f"Frame error: {e}\n")
                sys.stderr.flush()
                time.sleep(0.5)


def main():
    args = [arg for arg in sys.argv[1:] if arg]
    udid = args[0] if args else None
    asyncio.run(stream(udid))


if __name__ == '__main__':
    main()
