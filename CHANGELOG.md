# Changelog

## 1.1.0 - 2026-10-11

- **Custom tail.** A third choice after a take: type the pause after the last
  release, in seconds (Free) or beats (BPM). `1.00` is a Width of 100 %. The
  field is prefilled with what was recorded.
- **High and Low.** The value while the key is held and the value between
  taps. Remembered between runs.
- **Absolute or Relative.** Relative writes the values as offsets and clears
  any absolute value left on a step.
- The final dialog states the value type, High and Low.

## 1.0.2 - 2026-10-11

- A temp slot counts as free only if both the command line and the pool see
  nothing there.
- Temp objects are deleted by name, never by number alone.
- Leftovers from a take that was killed are listed and asked about.
- Only the tap key's timecode track is read. Events from other playbacks
  recorded during the take are ignored and counted in the review dialog. If
  the tap track cannot be identified, nothing is written.
- The temp timecode is forced to Keep Playbacks.
- The Record dialog warns when another timecode is running.
- A Shape that already existed is never written into or deleted.

## 1.0.1 - 2026-10-11

- The direct route sets transitions through the `Curve` property. On 2.5.1 a
  plain `TransX 0` returns OK but reads back as 100, which made 1.0.0 discard
  its direct write and fall back to the programmer route, which needs a
  selected fixture.
- Transitions that still read wrong get a second try with other spellings.
- Accel and Decel are checked in the read-back.

## 1.0.0 - 2026-10-11

First working version, not tagged in this repository.

- Tap key on a temp sequence, set to Flash.
- Capture by temp timecode; run the plugin again to end.
- Keep tail, Chop, Retake. Free and BPM modes. Snap, Pluck, Swell, Smooth.
- Writes a Shape, with a programmer fallback, and reads it back to check.
- Re-render last take.
