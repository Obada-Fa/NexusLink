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
    def test_encoder_specific_keyframe_properties_and_preference(self):
        cases = [
            ({"vah264enc", "vaapih264enc"}, "vah264enc", "key-int-max"),
            ({"vaapih264enc", "nvh264enc"}, "vaapih264enc", "keyframe-period"),
            ({"nvh264enc"}, "nvh264enc", "gop-size"),
            (set(), "x264enc", "key-int-max"),
        ]
        for installed, encoder, key_property in cases:
            with self.subTest(encoder=encoder):
                factory = SimpleNamespace(find=installed.__contains__)
                with patch.object(agent, "Gst", SimpleNamespace(ElementFactory=factory)):
                    options = agent.pick_h264_encoder(4000, 48).split()
                self.assertEqual(options[0], encoder)
                self.assertIn("bitrate=4000", options)
                self.assertIn(f"{key_property}=48", options)


if __name__ == "__main__":
    unittest.main()
