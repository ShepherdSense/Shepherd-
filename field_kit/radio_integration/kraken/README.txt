KrakenSDR Bench Capture -- README
===================================

WHAT THIS DOES
Polls your KrakenSDR's DOA_value.html page (http://<pi-ip>:8081) once per
second for 5 minutes and records every NEW bearing line -- capture time
plus the raw DSP fields (timestamp, bearing, confidence, power, frequency)
-- to kraken_bench_<date>_<time>.jsonl in this folder. This file is the
bench-test evidence the Shepherd Kraken driver needs: it locks the bearing
convention (is the field 360-theta or theta? true or magnetic reference?)
against YOUR hardware before it gets baked into code.

HOW TO RUN THE BENCH TEST (double-click simple)
1. In the Kraken web UI, park a VFO on a KNOWN emitter at a KNOWN bearing
   from the array -- your own test transmitter is ideal, or a local
   broadcast station whose direction from your array you can measure on
   a map. Set "DOA Data Format" to Kraken App. Note the true bearing and
   which way the array's channel-0 antenna points (array heading).
2. Double-click RUN_KRAKEN_BENCH.bat, enter the Pi's IP when asked.
   Let it poll 5 minutes while the emitter is on (Ctrl+C stops early).
3. Send back the newest kraken_bench_*.jsonl AND the known true bearing
   of the emitter plus the array heading. That pair is what settles the
   convention -- measured geometry vs reported numbers, no guessing.

WHAT THE RESULTS MEAN
- You see [bearing] lines with numbers that move as you expect: the CSV
  path works and the capture is exactly the evidence needed.
- Only [squelch closed] lines: the DSP sees no signal -- check the VFO
  frequency, gain, and that squelch is open or off in the Kraken UI.
- [http-error] lines: the Pi IP is wrong or the Kraken software isn't
  running. Ping the Pi first.
- If your Kraken runs the newer krakensdr_suite (Heimdall v2, C++ rewrite),
  the live stream is a WebSocket on port 8021, not this file -- the script
  detects that generation (heimdall web UI on :8070) and says so. Two V2
  facts to know: (1) the :8021 broadcast is OPT-IN -- turn it on in the
  web UI's Web Mapper panel -> Local Network WS broadcast; a closed 8021
  on V2 just means the toggle is off, not that anything is broken.
  (2) the web UI moved to https://<pi-ip>:8080 (client) and
  http://<pi-ip>:8070 (heimdall). The :8081 CSV check this script runs
  works on V2 unchanged.

NOTES
- Pure Python, zero installs. Read-only: it only GETs a status page.
- Default poll is 1 Hz; use --minutes N for a longer run.
- Bearings exist only for EMITTERS. This test says nothing about dark
  (non-emitting) targets -- that blind spot is unchanged.
