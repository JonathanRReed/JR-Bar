from jrbar import daemon_loop as dl


def test_serial_loop_orders_callbacks_and_cancels_timers(monkeypatch):
    loop = dl.DaemonLoop()
    monkeypatch.setattr(dl, "_application", loop)
    calls = []

    class Controller(dl.DaemonObject):
        def applicationDidFinishLaunching_(self, _):
            self.performSelectorOnMainThread_withObject_waitUntilDone_("ready:", "queued", False)
            canceled = dl.Timer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(0, self, "bad:", None, False)
            canceled.invalidate()
            dl.Timer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(0, self, "done:", "timer-data", False)

        def ready_(self, value):
            calls.append(value)

        def bad_(self, timer):
            raise AssertionError("canceled timer ran")

        def done_(self, timer):
            calls.append(timer.userInfo())
            loop.terminate_(self)

        def applicationWillTerminate_(self, _):
            calls.append("shutdown")

    loop.setDelegate_(Controller())
    loop.run()
    assert calls == ["queued", "timer-data", "shutdown"]
    assert not loop.queue and not loop.timers
