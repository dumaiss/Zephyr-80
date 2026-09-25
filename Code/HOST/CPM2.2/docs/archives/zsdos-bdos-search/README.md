# ZSDOS BDOS search capture

These are the raw `BDOSCHAR V2` reports captured on the target ZSDOS system.
Drive B is reported as `01h`. USER 0, 1 and 15 are represented. The exact
ZSDOS build identity was not supplied with the capture.

| Report | Case |
|---|---|
| `BCDEF.TXT` | default-drive exact name |
| `BCEXP.TXT` | explicit-drive exact name |
| `BCWILD.TXT` | five wildcard matches and exhaustion |
| `BCEMPTY.TXT` | zero-record file |
| `BCRECORD.TXT` | record and extent boundaries |
| `BCATTR.TXT` | R/O, SYS, ARC and combined attributes |
| `BCU00.TXT` | USER 0 isolation |
| `BCU01.TXT` | USER 1 isolation |
| `BCU15.TXT` | USER 15 isolation |

The directory sectors visible in several reports contain a user-byte `1Fh`
entry left by the earlier generator. ZSDOS has no USER 31 area; the entry is an
invalid fixture artifact and is not characterization evidence for a supported
USER value.
