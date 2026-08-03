#!/usr/bin/env python3
"""Take a Stella snapshot with F12; the caller terminates Stella afterward."""

import time
from Xlib import X, XK, display, protocol


def mapped_windows(root):
    result = []
    try:
        attrs = root.get_attributes()
        if attrs.map_state == X.IsViewable:
            geom = root.get_geometry()
            result.append((geom.width * geom.height, root))
        children = root.query_tree().children
    except Exception:
        return result
    for child in children:
        result.extend(mapped_windows(child))
    return result


def send_key(dpy, root, window, name, control=False):
    state = X.ControlMask if control else 0
    control_code = None
    if control:
        control_code = dpy.keysym_to_keycode(XK.string_to_keysym("Control_L"))
        window.send_event(
            protocol.event.KeyPress(
                time=X.CurrentTime,
                root=root,
                window=window,
                same_screen=1,
                child=X.NONE,
                root_x=1,
                root_y=1,
                event_x=1,
                event_y=1,
                state=0,
                detail=control_code,
            ),
            propagate=True,
        )

    code = dpy.keysym_to_keycode(XK.string_to_keysym(name))
    for event_type in (protocol.event.KeyPress, protocol.event.KeyRelease):
        window.send_event(
            event_type(
                time=X.CurrentTime,
                root=root,
                window=window,
                same_screen=1,
                child=X.NONE,
                root_x=1,
                root_y=1,
                event_x=1,
                event_y=1,
                state=state,
                detail=code,
            ),
            propagate=True,
        )

    if control_code is not None:
        window.send_event(
            protocol.event.KeyRelease(
                time=X.CurrentTime,
                root=root,
                window=window,
                same_screen=1,
                child=X.NONE,
                root_x=1,
                root_y=1,
                event_x=1,
                event_y=1,
                state=0,
                detail=control_code,
            ),
            propagate=True,
        )
    dpy.sync()


def main():
    dpy = display.Display()
    root = dpy.screen().root
    window = None
    for _ in range(100):
        candidates = [item for item in mapped_windows(root) if item[1].id != root.id]
        if candidates:
            window = max(candidates, key=lambda item: item[0])[1]
            break
        time.sleep(0.05)
    if window is None:
        raise SystemExit("no mapped Stella window appeared")

    window.set_input_focus(X.RevertToParent, X.CurrentTime)
    dpy.sync()
    time.sleep(0.30)
    send_key(dpy, root, window, "F12")
    time.sleep(0.35)


if __name__ == "__main__":
    main()
