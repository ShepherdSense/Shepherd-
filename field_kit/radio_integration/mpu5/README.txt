Persistent Systems MPU5 SNMP probe
====================================

WHAT THIS IS
A read-only survey of your MPU5's SNMP management interface. It asks
the radio what it is (sysDescr/sysObjectID), lists its network
interfaces, walks the vendor-specific section, and then flags any
values that look like signal data (dBm-range numbers, neighbor/link
named strings) as candidates for the Shepherd driver. It changes
NOTHING on the radio.

WHY
Shepherd talks to radios through small "driver" modules. The Silvus
driver was built from Silvus's telemetry API. For the MPU5 there is no
public telemetry doc, so this probe discovers empirically what the
radio exposes. The walk file you send back is what the Shepherd MPU5
driver gets built from.

HOW TO RUN
1. Connect the MPU5 to your LAN and note its IP address.
2. Make sure its SNMP agent is enabled (management settings on the
   MPU5 — your comms shop will know). Default SNMPv2c community is
   often "public"; use whatever yours is set to.
3. Double-click RUN_MPU5_PROBE.bat, enter the IP when asked.
   Or from PowerShell for more control:
     python mpu5_snmp_probe.py --ip 192.168.1.50 --community public
4. Needs only Python 3. No installs, no internet, no extra packages —
   the SNMP protocol is built into the script.
5. It writes mpu5_snmp_walk_<ip>_<time>.txt in the same folder.
   Send that file back to Spark.

SCOPE
SNMP GET and walk only. Read-only against the radio's management
interface — the probe never changes configuration and never touches
the RF side.
