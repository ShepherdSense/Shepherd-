MRSI Probe -- BEAST+ bearing capture
=========================================

WHAT THIS DOES
Talks to the BEAST+ over CACI's MRSI JSON API (TCP 10051), subscribes to
its receive-only data streams -- line-of-bearing (lob), signal hits,
compass -- and logs every byte for 5 minutes to mrsi_probe_<date>.jsonl
in this folder. That capture gives the EXACT JSON schema Shepherd's
ingest driver must parse: measured from your unit, not guessed.

SCOPE: SUBSCRIBE-ONLY. This probe never sends jamming (EA) commands and
never reconfigures the sensor -- no rf_*, soi_*, scan_*, mission or ea_*
commands. It connects, lists streams, subscribes, listens, and
disconnects politely. It cannot change what your unit is doing.

HOW TO RUN IT (double-click simple)
1. Power on the BEAST+ and connect it to the same LAN as this PC
   (Ethernet or however your unit gets an IP on your network).
2. Put the BEAST+ in DF / surveillance so it has bearings to emit.
3. Double-click RUN_MRSI_PROBE.bat. It first listens 15 seconds for the
   unit's discovery hello, then connects and captures for 5 minutes
   (Ctrl+C stops early).
4. If no hello is heard, it asks for the unit's IP -- type it and Enter.
5. Send the newest mrsi_probe_*.jsonl file back. That's it.

WHAT THE RESULTS MEAN
- You see "Subscribed ... -> your-IP:port" and a growing UDP count:
  the unit is streaming. The file has everything needed to build the
  Shepherd driver.
- TCP connects but no UDP arrives: the handshake is still logged --
  send the file; it shows how far the unit got (auth? stream names?).
- TCP refused / no hello / no IP: the unit isn't reachable at TCP
  10051 on this LAN right now. Check it's powered, on the network,
  and its MRSI/data service is enabled. Note how it's connected.

NOTES
- Pure Python, zero installs. Your firewall may ask once to allow
  Python on the network -- allow it (private networks).
- The probe never transmits anything except the MRSI session itself
  (connect / subscribe / disconnect). All sensor data flows one way:
  unit -> this PC.
