#!/usr/bin/env python3
"""Runs TapPhaser.lua against tests/fake_console.lua.

    pip install lupa          # bundles Lua 5.4, the version grandMA3 uses
    python3 tests/run_tests.py            # all cases
    python3 tests/run_tests.py hi_lo -v   # one case, with the plugin's log

Each case scripts the dialogs and the taps, then checks which route wrote
the Shape and, for some cases, what ended up in it.
"""
import pathlib
import sys
import tempfile

from lupa import lua54

HERE = pathlib.Path(__file__).resolve().parent
PLUGIN = HERE.parent / "TapPhaser.lua"
FAKE = HERE / "fake_console.lua"

# five taps: short, short, long, a 16 ms blip, long
TAPS = "{ {0.50, 0.60}, {1.00, 1.10}, {1.25, 1.90}, {2.50, 2.516}, {3.00, 3.75} }"
BASE = f'exec="203", mode=1, feel=1, review=1, direct=true, taps={TAPS}, endAt=4.50'

# name: (config, route that must verify or None for "no shape", text that must appear)
CASES = {
    "free_keep":            (f"{{ {BASE} }}", 1, "A0/75.7"),
    "free_chop":            (f"{{ {BASE}, review=2 }}", 1, "measure=3.25"),
    "custom_tail_free":     (f'{{ {BASE}, review=4, customTail="1.00" }}', 1, "A0/100.0"),
    "custom_tail_bpm":      (f'{{ {BASE}, mode=2, bpm=120, grid=2, review=4, customTail="0.5", endAt=4.40 }}', 1, "measure=7.0"),
    "bad_custom_then_ok":   (f'{{ {BASE}, review=4, customTail="" }}', 1, "not a usable tail length"),
    "bpm_keep_pluck":       (f"{{ {BASE}, mode=2, bpm=120, grid=2, feel=2, endAt=4.40 }}", 1, "measure=8.0 speed=120"),
    "hi_lo":                (f'{{ {BASE}, feel=2, review=2, hi="80", lo="20" }}', 1, "A80/10.0/0/0/0  A20/40.0/100/0/0"),
    "relative":             (f'{{ {BASE}, review=2, rel=true, hi="30", lo="-30" }}', 1, "R30/10.0/0/0/0  R-30/40.0"),
    "relative_abs_default": (f'{{ {BASE}, review=2, rel=true, hi="30", lo="-30", absDefault=true }}', 1, "R30/10.0"),
    "relative_abs_sticky":  (f'{{ {BASE}, review=2, rel=true, hi="30", lo="-30", absDefault=true, absSticky=true }}', 2, "R30/10.0"),
    "relative_fallback":    (f'{{ {BASE}, review=2, rel=true, hi="30", lo="-30", direct=false }}', 2, "R-30/40.0"),
    "rerender":             (f'{{ {BASE}, sessions={{"record","rerender"}} }}', 1, "Shape 2 "),
    "held_at_end":          ('{ exec="203", mode=1, feel=1, review=1, direct=true, taps={ {0.5,0.7}, {1.5} }, endAt=2.0 }', 1, "A100/50.7"),
    "no_taps":              ('{ exec="203", mode=1, feel=1, review=1, direct=true, confirm=false, taps={}, endAt=2.0 }', None, "0 events -> 0 taps"),
    "blank_exec_occupied":  (f'{{ {BASE}, exec="", feel=2, review=2, direct=false, occupied=true, stray=true }}', 2, "202=Sequence 5 key=Toggle"),
    "typed_exec_occupied":  (f'{{ {BASE}, exec="202", occupied=true }}', None, "already holds Sequence 5"),
    "other_tracks":         (f"{{ {BASE}, otherTracks=true }}", 1, "8 events from 2 other playbacks"),
    "unidentified_track":   (f"{{ {BASE}, otherTracks=true, noTarget=true, confirm=false }}", None, "none could be identified"),
    "slots_taken":          (f'{{ {BASE}, pre={{ {{"Sequence",9901,"Song 1"}}, {{"Macro",9901,"My macro"}}, {{"Timecode",9901,"Show TC",true}}, {{"Shape",1,"Sine"}}, {{"Shape",2,"Chase"}} }} }}', 1, "Shape 3 "),
    "leftovers":            (f'{{ {BASE}, exec="", pre={{ {{"Sequence",9901,"TAP PHASER TEMP"}}, {{"Timecode",9903,"TAP PHASER TEMP"}}, {{"Sequence",9902,"Keep me"}} }} }}', 1, "OBJECTS LEFT: Attribute \"Dimmer\", Sequence 9902, Shape 1"),
    "stubborn_switchoff":   (f"{{ {BASE}, stubborn=true }}", 1, "SwitchOff = 'Keep Playbacks'"),
    "fallback_no_selection": (f"{{ {BASE}, direct=false, noSelection=true }}", None, "needs one selected fixture"),
}

LOADER = ('function(src, a, b, cfg) local fn, e = load(src, "@fake_console.lua") '
          'if not fn then error(e, 0) end return fn(a, b, load("return " .. cfg)()) end')


def run(name, verbose):
    cfg, route, must = CASES[name]
    lua = lua54.LuaRuntime(unpack_returned_tuples=True)
    with tempfile.TemporaryDirectory() as lib:
        try:
            out = lua.eval(LOADER)(FAKE.read_text(), str(PLUGIN), lib, cfg)
        except Exception as e:                      # a Lua error inside the plugin or the fake
            return False, f"crashed: {e}"
    if verbose:
        print(out)
    verified = [int(l.split("route ")[1][0]) for l in out.splitlines() if "route " in l and ": VERIFIED" in l]
    new_shapes = [l for l in out.split("SHAPES:")[-1].splitlines() if l.startswith("Shape ") and "was there before" not in l]
    if route is None:
        if new_shapes:
            return False, "a shape was written, none expected"
    elif not verified or verified[-1] != route:
        return False, f"expected route {route} to verify, got {verified or 'nothing'}"
    if must not in out:
        return False, f"missing: {must!r}"
    return True, ""


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    verbose = "-v" in sys.argv
    names = args or list(CASES)
    failed = 0
    for name in names:
        ok, why = run(name, verbose)
        print(f"{'ok  ' if ok else 'FAIL'}  {name}{'' if ok else '   ' + why}")
        failed += not ok
    print(f"\n{len(names) - failed} of {len(names)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
