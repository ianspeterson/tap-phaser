# Tap Phaser

A grandMA3 Lua plugin. Tap a rhythm on an executor key and get it back as a
**Shape**: a phaser recipe you can assign to any recipe line or call on a
selection.

It records when you press and when you release, so short hits and long holds
both come through, along with the gaps between them.

## Status

Written for grandMA3 **2.5.1** and developed on onPC (macOS).

- The capture and the programmer route (route 2 below) have produced checked
  Shapes on a real onPC session.
- The direct route (route 1) as fixed in 1.0.1, and everything added in 1.0.2
  and 1.1.0, pass the offline tests. The log says which route wrote each
  Shape.
- That session had no DMX output, so the timing of the finished Shape has been
  judged by eye, not measured.
- Relative values, added in 1.1.0, are the least field-tested part. See
  [Known limits](#known-limits).

## Install

1. Copy `TapPhaser.lua` and `TapPhaser.xml` into
   `gma3_library/datapools/plugins`.
2. In the plugin pool, import `TapPhaser.xml`.
3. After updating the `.lua`, reload the plugin. The dialog title shows the
   version that is actually loaded.

## Use

1. Run the plugin. Fill in the first dialog (see [Options](#options)) and press
   **Start**.
2. Pick the tap key. Either type an empty executor number, or leave it blank:
   `Assign Sequence N At` appears in the command line and you press the key.
3. Press **Record**, then tap. The loop starts on your first press.
4. **Run the plugin again to end the take.**
5. Choose what happens after the last release:
   - **Keep tail** keeps the pause you left before ending.
   - **Chop** has no pause; the loop restarts at the last release.
   - **Custom tail** uses the pause you type.
   - **Retake** records again on the same key.
6. The Shape is written, read back and checked. The last dialog can call it on
   your current selection.

**Re-render last take** on the first dialog rebuilds the Shape from the last
take with different settings, without tapping again.

Whatever is in the programmer when you start is stored in the temp sequence,
so that is what flashes while you tap.

## Options

| Option | What it does |
|---|---|
| Executor | An empty executor on the current page. Blank means you press a key yourself. |
| Mode | **Free** keeps your timing exactly. **BPM** snaps presses and releases to a grid. |
| BPM | Tempo for BPM mode. Typed; it is not linked to a speed master. |
| Grid | 1/4, 1/8, 1/16, 1/8 triplet, 1/16 triplet. BPM mode only. |
| Feel | **Snap** hard on and off. **Pluck** hard on, fades out over the gap. **Swell** fades in over the hold, hard off. **Smooth** eased both ways. |
| High / Low | The value while the key is held, and the value between taps. |
| Values | **Absolute** sets the dimmer to those values. **Relative** adds them to what the dimmer is already doing, so they can be negative. |
| Shape number | Blank uses the first free Shape. A number that exists asks before replacing. |
| Name | Blank names it `Tap` plus the time. |

The custom tail is typed in seconds in Free mode and in beats in BPM mode.
Either way it is the last step's Width divided by 100, so `1.00` is a Width of
100 %.

## What it creates

One object is kept: the **Shape**.

Everything else is temporary, named `TAP PHASER TEMP`, uses the first free
number from 9901 to 9990, and is deleted when the take ends:

- a sequence with one cue, assigned to the tap key with the key set to Flash
- a macro with one line, only when Executor is left blank
- a timecode, one per take

It also keeps your last settings and last take in user variables named
`TapPhaser_...`, and appends to `TapPhaser_log.txt` in `gma3_library`.

## Safe around a running show

- A temp slot counts as free only if both the command line and the pool see
  nothing there.
- Temp objects are deleted by name, never by number alone.
- A typed executor that is in use is refused. In blank mode, a key that was in
  use gets its old assignment and key function back.
- The timecode records every playback triggered during the take. Only the
  track of the tap key is read; the review dialog says how many other events
  were ignored. If the tap track cannot be identified, nothing is written.
- The temp timecode is set to **Keep Playbacks**, so ending a take cannot
  switch anything else off.
- If another timecode is running, the Record dialog names it. If that one is
  recording, your taps land in it too; the plugin cannot prevent that.
- A Shape that already existed is never written into or deleted.

If MA is closed or the plugin is killed mid-take, the temp objects stay behind.
The next run lists them and asks before deleting.

## How it works

1. **Capture.** A temp timecode records the tap key. MA writes a `Flash` event
   on each press and a `Flash(Release)` on each release, on a 1/60 s grid.
   Polling from Lua was tried first and dropped a 16 ms tap.
2. **End.** The plugin keeps a flag in memory between launches, so the second
   launch sets it and exits.
3. **Steps.** Each hold becomes an "on" step and each gap an "off" step. A
   step's Width is its length as a percentage of one beat, and Measure is set
   to the sum, so the loop is exactly as long as the take. Free mode treats one
   beat as one second.
4. **Write.** Route 1 creates an empty Shape and writes the steps directly,
   leaving the programmer alone. If the read-back does not match the plan,
   route 2 writes a programmer phaser on the selected fixture, stores that as
   the Shape, and knocks the attribute out again.
5. **Check.** Every step is read back and compared with the plan before the
   plugin reports success.

One quirk worth knowing: on 2.5.1, `Set ... Property "TransX" 0` returns OK on
a recipe step but does not stick. The plugin sets transitions through the
`Curve` property (`Snap`, `Linear`), which does.

## Known limits

- **Dimmer only.**
- **Relative values** rely on the `ValueRelative` step property. If a step
  keeps an absolute value alongside, the plugin tries to clear it, and
  otherwise falls back to route 2. Route 2 needs one dimmable fixture
  selected and a clear programmer, since other programmer values would end up
  in the Shape.
- **Route 2 sends plain numbers**, which MA reads through your readouts. It
  has only been run with Value readout Natural and Speed readout BPM.
- **BPM mode** rounds a kept tail to whole beats. A custom tail is used as
  typed.
- **Timing resolution** is one frame, about 17 ms.
- A single step can be at most 3200 % wide, so longer holds and gaps are split
  into several steps of the same value.

## Also in this repo

`tools/TapPhaserProbe.lua` is the diagnostic plugin used to find the syntax
and timing facts above: clock resolution, tap capture three ways, phaser
timing, and a phaser recipe build.

## Credits

Created by Ian Peterson.
