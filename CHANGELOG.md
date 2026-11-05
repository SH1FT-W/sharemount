# Changelog

All notable changes to ShareMount. Every release is also listed with its notes on the
[releases page](https://github.com/SH1FT-W/sharemount/releases).

## 26.11.1 (2026-11-05)

### Added
- **Only on certain networks.** A share can be limited to a list of networks (for example "Home network").
  Elsewhere it is not connected automatically and shows *Away, paused* instead of an error; a click on the
  share still connects. Networks are recognised by the MAC address of their router, without Location
  Services, on Wi-Fi and Ethernet alike. *Add Current Network* captures the network you are on, *Known*
  reuses networks from other shares.
- **Wake on LAN.** Optional MAC address per server. If the server does not answer, ShareMount sends a magic
  packet, waits up to 60 seconds and then connects as usual. At most one packet every 5 minutes per server
  (a click on the share sends one right away). Needs a network rule: the packet only goes out while the Mac
  is on one of the share's networks; without networks set, the share editor shows a hint next to the MAC field.
- Self tests for the network rules, the neighbour table parser and the magic packet.

### Changed
- **Signed updates.** Releases are signed with Ed25519, and the update button installs a release only if its
  signature matches the key built into the app. This release is the first one signed; it still installs from
  older versions as usual.
- Release tags and titles are the bare version, without "v".

### Notes
- `shares.json` gains the optional fields `networks` and `wakeMAC`. Older versions ignore them, and drop them
  when they save the list, so update all Macs that share the list via iCloud Drive.
