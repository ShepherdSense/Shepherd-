SHEPHERD RADIO INTEGRATION KIT
==============================
One bundle for every radio probe / integration script: Kraken, BEAST+,
MPU5, and L3Harris. Each folder is double-click simple — run the .bat,
send the output file back to Spark, and the matching Shepherd driver
gets built.

Every script here is RECEIVE-ONLY (subscribe / listen / survey). Nothing
transmits, nothing sends commands to a radio. That is the standing rule.

FOLDERS
-------
mpu5/
  WHAT:     Read-only SNMP survey for the Persistent Systems MPU5.
  RUN:      RUN_MPU5_PROBE.bat (it asks for the radio's IP).
  SEND BACK: mpu5_snmp_walk_*.txt  ->  then the MPU5 driver gets built.
  STATUS:   CURRENT — this is the live path.

beast_mrsi/
  WHAT:     Subscribe-only probe for the CACI BEAST+ MRSI API
            (bearings, spectrum, IQ — never EA/transmit commands).
  RUN:      RUN_MRSI_PROBE.bat
  SEND BACK: mrsi_probe_*.jsonl  ->  then the ingest driver gets built.
  STATUS:   CURRENT — this is the live path.

beast_cot/
  WHAT:     Captures the BEAST+'s ATAK/Reaper CoT output for analysis.
  RUN:      RUN_BEAST_CAPTURE.bat
  SEND BACK: the capture file it writes.
  STATUS:   CURRENT.

kraken/
  WHAT:     Bench capture for Kraken-family direction finding.
  RUN:      RUN_KRAKEN_BENCH.bat
  STATUS:   STAGED — waiting on one answer: is your Kraken the CACI
            tactical unit or the $749 KrakenSDR board? The driver spec
            stays parked until that's settled. Don't run this yet.

l3harris_cot/
  WHAT:     Listens for CoT traffic (the live AN/PRC-163 position path:
            PLI rides the waveform to ATAK/WINTAK, then CoT over TCP).
  RUN:      RUN_COT_LISTENER.bat
  STATUS:   CURRENT.

l3harris_snmp_RETIRED/
  WHAT:     Old SNMP probe for the AN/PRC-163.
  STATUS:   RETIRED — DO NOT USE. SNMP is not documented on the 163 at
            all (L3Harris Radio Application Handbook: the USB cable is
            the serial programming interface, no IP/SNMP/CoT by design).
            Kept in the bundle so nothing is lost, but the CoT path
            above is the real one.

QUICK START
-----------
1. Pick the folder for your radio.
2. Double-click the .bat.
3. Send the output file back to Spark.
