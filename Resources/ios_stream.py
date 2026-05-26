#!/usr/bin/env python3
"""
Persistent iOS screen streaming helpers.

Default mode uses pymobiledevice3 screenshots:
    [4 bytes big-endian length][PNG data] repeated

Low-latency mode uses ioscreen's QuickTime USB feed:
    Annex B H.264 NAL units written directly to stdout
"""

import sys
import struct
import time
import json
import asyncio
import urllib.request
import io
import threading


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


def stream_h264(udid=None):
    """Stream the device's native H.264 feed to stdout for ffplay."""
    try:
        import usb
        from ioscreen.coremedia.CMFormatDescription import DescriptorConst
        from ioscreen.coremedia.consumer import Consumer, startCode
        import ioscreen.util as ioscreen_util
    except Exception as e:
        sys.stderr.write(f"ERROR: ioscreen is not available: {e}\n")
        sys.stderr.flush()
        sys.exit(1)

    def normalize_udid(value):
        if value is None:
            return None
        return str(value).replace('\x00', '').replace('-', '').strip()

    def ioscreen_udid_candidates(raw_udid):
        """ioscreen's USB serial omits the dash used by libimobiledevice UDIDs."""
        if not raw_udid:
            return [None]

        cleaned = raw_udid.strip().replace('\x00', '')
        candidates = [
            cleaned,
            cleaned.replace('-', ''),
        ]

        # If the exact lookup fails, a no-argument lookup is still useful for
        # the common case of one iPhone connected over USB.
        candidates.append(None)

        deduped = []
        for candidate in candidates:
            if candidate in deduped:
                continue
            deduped.append(candidate)
        return deduped

    def robust_find_ios_device(raw_udid=None, timeout=2.0):
        class find_class(object):
            def __init__(self, class_):
                self._class = class_

            def __call__(self, device):
                if device.bDeviceClass == self._class:
                    return True
                for cfg in device:
                    intf = usb.util.find_descriptor(
                        cfg,
                        bInterfaceSubClass=self._class
                    )
                    if intf is not None:
                        return True
                return False

        target = normalize_udid(raw_udid)
        deadline = time.time() + timeout
        last_error = None

        while True:
            devices = usb.core.find(find_all=True, custom_match=find_class(0xfe))
            for device in devices:
                if not target:
                    return device
                try:
                    serial = normalize_udid(device.serial_number)
                except Exception as e:
                    last_error = e
                    continue
                if serial and target in serial:
                    sys.stderr.write(f"Find Device UDID: {device.serial_number}\n")
                    sys.stderr.flush()
                    return device

            if time.time() >= deadline:
                break
            time.sleep(0.1)

        if last_error:
            sys.stderr.write(f"Device lookup warning: {last_error}\n")
            sys.stderr.flush()
        if raw_udid:
            raise Exception(f"not find {raw_udid}")
        sys.stderr.write("WARNING: no raw iOS USB device found\n")
        sys.stderr.flush()
        sys.exit()

    def find_h264_device(raw_udid):
        last_error = None
        for candidate in ioscreen_udid_candidates(raw_udid):
            try:
                return robust_find_ios_device(candidate)
            except SystemExit:
                raise
            except Exception as e:
                last_error = e
                if candidate:
                    sys.stderr.write(f"Device lookup failed for {candidate}: {e}\n")
                    sys.stderr.flush()

        raise last_error or Exception(f"not find {raw_udid}")

    class StdoutH264Consumer(Consumer):
        def __init__(self):
            self.stdout = sys.stdout.buffer
            self.frame_count = 0
            self.start_time = time.time()

        def consume(self, data):
            if data.MediaType != DescriptorConst.MediaTypeVideo:
                return True

            if data.HasFormatDescription:
                self.write_nalu(data.FormatDescription.SPS)
                self.write_nalu(data.FormatDescription.PPS)

            if data.SampleData:
                buf = data.SampleData
                while buf:
                    nalu_length = struct.unpack('>I', buf[:4])[0]
                    self.write_nalu(buf[4:nalu_length + 4])
                    buf = buf[nalu_length + 4:]

                self.stdout.flush()
                self.frame_count += 1
                if self.frame_count % 60 == 0:
                    elapsed = max(time.time() - self.start_time, 0.001)
                    sys.stderr.write(f"h264_fps={self.frame_count / elapsed:.1f} frames={self.frame_count}\n")
                    sys.stderr.flush()
            return True

        def write_nalu(self, nalu):
            if not nalu:
                return
            self.stdout.write(startCode)
            self.stdout.write(nalu)

        def stop(self):
            try:
                self.stdout.flush()
            except BrokenPipeError:
                pass

    stop_signal = threading.Event()
    ioscreen_util.register_signal(stop_signal)
    ioscreen_util.find_ios_device = robust_find_ios_device

    try:
        device = find_h264_device(udid)
        ioscreen_util.start_reading(StdoutH264Consumer(), device, stop_signal)
    except BrokenPipeError:
        stop_signal.set()
    except KeyboardInterrupt:
        stop_signal.set()
    except Exception as e:
        sys.stderr.write(f"ERROR: H.264 stream failed: {e}\n")
        sys.stderr.flush()
        sys.exit(1)


def main():
    args = [arg for arg in sys.argv[1:] if arg]
    if "--h264" in args:
        args.remove("--h264")
        udid = args[0] if args else None
        stream_h264(udid)
        return

    udid = args[0] if args else None
    asyncio.run(stream(udid))


if __name__ == '__main__':
    main()
