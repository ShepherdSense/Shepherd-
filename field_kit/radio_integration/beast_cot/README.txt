BEAST+ CoT Capture -- README
==============================

WHAT THIS DOES
Listens for Cursor-on-Target (CoT) traffic -- the message format ATAK and
most tactical tools speak -- on your LAN for 5 minutes and saves everything
it hears to beast_capture_<date>_<time>.jsonl in this folder. The BEAST+
talks to ATAK through CACI's Reaper plug-in, so if it emits standard CoT
onto the network, this capture reveals the EXACT message schema Shepherd's
ingest driver needs -- no CACI paperwork required.

HOW TO RUN IT (double-click simple)
1. Power on the BEAST+ and connect it to the same LAN as this PC
   (whatever way you normally link it to ATAK).
2. Let the BEAST+ do something -- run a DF sweep or leave it in
   surveillance -- so it has traffic to emit.
3. Double-click RUN_BEAST_CAPTURE.bat. A window opens and listens for
   5 minutes (Ctrl+C stops early).
4. Send the newest beast_capture_*.jsonl file back. That's it.

WHAT THE RESULTS MEAN
- You see [CoT] lines with IDs/callsigns/coordinates: the BEAST+ speaks
  standard CoT on your LAN. The capture file has everything needed to
  spec and build the Shepherd ingest driver.
- You see only [other] lines: something is talking, but not CoT. Send
  the file anyway -- the raw bytes may still identify the protocol.
- Total silence: the BEAST+ is NOT putting traffic on this LAN right now.
  That is a real finding, not a broken script. It usually means the unit
  talks to its Android EUD (Diablo/Reaper) over USB or Bluetooth instead,
  or its TAK link isn't configured yet. Note how yours is connected and
  we'll go the next route (Ice Bucket app export, or CACI interface docs).

NOTES
- Pure Python, zero installs. Your firewall may ask once to allow Python
  on the network -- allow it (private networks).
- The listener never transmits anything. It only receives.
