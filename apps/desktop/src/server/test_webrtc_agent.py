import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "webrtc_agent", Path(__file__).with_name("webrtc-agent.py")
)
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)


class EncoderChoiceTest(unittest.TestCase):
    def test_only_selects_an_encoder_on_the_pinned_device(self):
        target = Path("/dev/dri/renderD129")
        wrong_device = SimpleNamespace(
            find_property=lambda _: True, get_property=lambda _: "/dev/dri/renderD128"
        )
        right_device = SimpleNamespace(
            find_property=lambda _: True, get_property=lambda _: str(target)
        )
        for factories, legacy, expected in [
            ({"vah264enc": right_device}, True, "vah264enc"),
            ({"vah264enc": wrong_device, "varenderD129h264enc": right_device}, True, "varenderD129h264enc"),
            ({"vah264enc": wrong_device}, True, "vaapih264enc"),
            ({"vah264enc": wrong_device}, False, None),
        ]:
            with self.subTest(expected=expected):
                factory = SimpleNamespace(make=factories.get, find=lambda _: legacy)
                with patch.object(agent, "Gst", SimpleNamespace(ElementFactory=factory)):
                    if expected is None:
                        with self.assertRaisesRegex(RuntimeError, "No GStreamer VA-API H.264 encoder"):
                            agent.pick_h264_encoder(target)
                    else:
                        self.assertEqual(agent.pick_h264_encoder(target), expected)

    def test_encoder_specific_properties(self):
        modern = agent.encoder_properties("vah264enc", 3000, 48)
        legacy = agent.encoder_properties("vaapih264enc", 3000, 48)
        self.assertIn("key-int-max=48 b-frames=0", modern)
        self.assertIn("keyframe-period=48 max-bframes=0", legacy)
        for properties in (modern, legacy):
            self.assertIn("bitrate=3000", properties)
            self.assertIn("rate-control=cbr", properties)

    def test_ximagesrc_uses_inclusive_end_coordinates(self):
        self.assertEqual(
            agent.crop_properties((100, 80, 1100, 850)),
            "startx=100 starty=80 endx=1199 endy=929",
        )
        with self.assertRaises(ValueError):
            agent.crop_properties((-1, 0, 640, 480))
        with self.assertRaises(ValueError):
            agent.crop_properties((0, 0, 641, 480))

    def test_size_preserves_aspect_within_constrained_baseline_level_31(self):
        for width, height, expected in [
            (720, 1280, (720, 1280)), (1920, 1080, (1280, 720)),
            (1080, 1920, (720, 1280)), (5120, 128, (2704, 66)),
        ]:
            with self.subTest(size=(width, height)):
                self.assertEqual(agent.level31_size(width, height), expected)


if __name__ == "__main__":
    unittest.main()
