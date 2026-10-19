L3Harris AN/PRC-163 — CoT position listener (Shepherd parallel path)
=========================================================================

WHAT THIS IS
-----------
A passive listener for Cursor-on-Target (CoT) traffic — the XML position
format used by ATAK / WinTAK / TAK servers. If your 163 is exporting
situational-awareness (SA) data onto your LAN, this script shows you each
position as it arrives and logs it to cot_log.jsonl.

WHY IT EXISTS
-------------
The SNMP probe got no answer from 192.168.1.3 — the radio side is silent
(SNMP agent disabled or restricted). While that question sits with the
radio/CPA side, this listener is the parallel path: IF the 163 can get
its GPS position onto the LAN, Shepherd can show it on the tracking map
(positions only — not the per-link signal telemetry the tripwire needs).

HONEST SCOPE
------------
- This is a LISTENER. It cannot make the radio emit anything.
- If you see nothing, the radio is not sending CoT/SA to your PC's LAN.
  That is a configuration fact, not a bug in this script.
- CoT carries positions only. It does NOT feed the disturbance detector.

HOW TO RUN
----------
1. Double-click RUN_COT_LISTENER.bat (or: python cot_listener.py)
2. Leave it running; Ctrl+C to stop.
3. Watch for lines like:  [+] EAGLE-1 (a-f-G-U-C-I) @ 35.139000,-79.006000  from 192.168.1.3

If nothing arrives after a few minutes, the 163 is not exporting SA to
your LAN. Typical ways SA gets onto the LAN: ATAK on a connected device
with the radio's SA plugin, a TAK server relaying the net, or a
radio-side SA bridge — check with your comms shop which applies.

COMMAND LINE
------------
  python cot_listener.py                      # multicast 239.2.3.1:6969
  python cot_listener.py --port 4242 --group ""  # plain unicast listen
  python cot_listener.py --out my_log.jsonl --verbose
  python cot_listener.py --self-test          # parser checks (no network)

No third-party packages needed — pure Python 3.
