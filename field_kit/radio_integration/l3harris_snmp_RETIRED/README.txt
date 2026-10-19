L3Harris PRC-163 SNMP probe
===========================

WHAT THIS IS
A read-only survey of your PRC-163's SNMP management interface. It asks
the radio what it is (sysDescr/sysObjectID), lists its network
interfaces, and walks the vendor-specific section where per-link signal
metrics (RSSI / SNR / neighbor quality) live — if the radio publishes
them. It changes NOTHING on the radio.

WHY
Shepherd talks to radios through small "driver" modules. The Silvus
driver was built from Silvus's telemetry API. For the PRC-163 there is
no public telemetry doc, so this probe discovers empirically what the
radio exposes. The walk file you send back is what the Shepherd
L3Harris driver gets built from.

HOW TO RUN
1. Connect the 163 to your LAN (Ethernet or USB-Ethernet) and note its
   IP address.
2. Make sure its SNMP agent is enabled (management settings in CPA —
   your comms shop will know). Default SNMPv2c community is often
   "public"; use whatever yours is set to.
3. Double-click Probe-163.bat, enter the IP when asked.
   Or from PowerShell for more control:
     python l3harris_snmp_probe.py --ip 192.168.1.50 --community public
4. Needs only Python 3. No installs, no internet, no extra packages —
   the SNMP protocol is built into the script.
5. It writes l3harris_snmp_walk_<ip>_<time>.txt in the same folder.
   Send that file back to Spark.

IF IT CAN'T REACH THE RADIO
"no SNMP answer" means the agent is off, the community/credentials are
wrong, or the PC can't route to the radio's IP. Check those three, then
re-run.

ONE HONEST NOTE
The 163's MANET waveforms (ANW2/TSM) are frequency-hopping military
waveforms. Per-link signal metrics may be coarse or absent compared to
the Silvus API — the probe shows us exactly what exists before anyone
promises a driver built on it.

Built by Spark for Draco, October 2026.
