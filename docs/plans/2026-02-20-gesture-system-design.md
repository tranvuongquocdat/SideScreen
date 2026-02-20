# Gesture System Redesign

## Summary

Redesign touch handling to support full gesture set: tap, double tap, long press (right click), long press + drag (drag & drop), 1-finger scroll with momentum, 2-finger scroll, and pinch zoom.

## Design Decisions

- Tablet = direct touch screen (absolute positioning, tap where you touch)
- 1-finger drag = scroll (not mouse move)
- Long press without movement = right click
- Long press + drag = drag & drop (left mouse down + drag)
- 2-finger = scroll + pinch zoom

## Protocol Change

Current: 13 bytes (1 type + 4 x + 4 y + 4 action)
New: variable (1 type + 1 pointerCount + N * 8 bytes + 4 action)

```
Byte 0:     type (2 = touch)
Byte 1:     pointerCount (1 or 2)
Byte 2-5:   x1 (float, normalized 0-1)
Byte 6-9:   y1 (float, normalized 0-1)
[if pointerCount == 2]
Byte 10-13: x2 (float)
Byte 14-17: y2 (float)
[end if]
Last 4:     action (int32)
```

1 finger: 14 bytes. 2 fingers: 22 bytes.

Action codes (unchanged): 0=down, 1=move, 2=up

## 1-Finger State Machine (Mac side)

```
IDLE
  └── touch_down → PENDING (start timer 500ms)

PENDING (waiting to determine gesture type)
  ├── move > 15px → SCROLLING
  ├── up < 250ms, < 15px → check double tap
  │    ├── previous tap < 400ms ago, < 20px → DOUBLE_TAP → click(state=2)
  │    └── else → single TAP → click(state=1)
  └── timer 500ms fires, < 15px → LONG_PRESS_READY
       ├── up → RIGHT_CLICK
       └── move > 15px → DRAGGING (leftMouseDown + leftMouseDragged)

SCROLLING
  ├── move → scrollWheelEvent(deltaX, deltaY)
  └── up → check momentum → MOMENTUM or IDLE

DRAGGING
  ├── move → leftMouseDragged
  └── up → leftMouseUp → IDLE

LONG_PRESS_READY
  ├── up → rightMouseDown + rightMouseUp → IDLE
  └── move > 15px → leftMouseDown → DRAGGING
```

## 2-Finger Gestures (Mac side)

Detected when pointerCount == 2:

**2-finger scroll**: Both fingers move in same direction
- Inject: scrollWheelEvent with averaged delta

**Pinch zoom**: Distance between fingers changes > 20px
- Inject: scrollWheelEvent with Cmd flag set (Cmd+scroll = zoom in most Mac apps)
- Scale factor = distance change mapped to scroll delta

Detection: track `initialPinchDistance` on 2-finger down.
- If distance change > 20px first → PINCHING mode
- If same-direction movement > 15px first → TWO_FINGER_SCROLL mode

## Android Changes

- Capture `event.pointerCount` and second pointer coordinates
- Send pointerCount + all pointer data in touch message
- Handle ACTION_POINTER_DOWN/UP for 2nd finger

## Mac Changes

- Parse new protocol format (pointerCount field)
- Replace simple threshold-based gesture with state machine
- Add CGEvent injection for: rightMouseDown/Up, leftMouseDragged, double click
- Add pinch-to-zoom (Cmd+scroll)

## Thresholds

```swift
tapMaxDistance: 15px
tapMaxTime: 250ms
doubleTapMaxTime: 400ms
doubleTapMaxDistance: 20px
longPressTime: 500ms
scrollMinDistance: 15px
pinchMinDistance: 20px
momentumThreshold: 2.0 px/frame
momentumDecay: 0.92
momentumMultiplier: 6.0
scrollSensitivity: 1.2
```
