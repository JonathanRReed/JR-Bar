"""Doctor observes the current process without loading GUI frameworks."""
import pytest

from jrbar import runtime_images


@pytest.mark.parametrize("images, expected", [([], False), (["/usr/lib/libobjc.A.dylib"], False),
    (["/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit"], True),
    (["/System/Library/Frameworks/_AppIntents_AppKit.framework/AppIntents_AppKit"], False)])
def test_appkit_presence_uses_exact_framework_component(monkeypatch, images, expected):
    monkeypatch.setattr(runtime_images, "loaded_images", lambda: images)
    assert runtime_images.appkit_loaded() is expected


def test_unavailable_inventory_is_unknown(monkeypatch):
    def unavailable():
        raise OSError
    monkeypatch.setattr(runtime_images, "loaded_images", unavailable)
    assert runtime_images.appkit_loaded() is None
