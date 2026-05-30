# Local External Libraries

Place local third-party headers and libraries here when they are not installed system-wide.

```text
external/
  include/   Header files, for example rfb/rfb.h
  lib/       Static or shared libraries
```

CMake uses this directory by default. Override it with:

```bash
cmake -S . -B build -DVIRTUAL_VDP_EXTERNAL_DIR=/path/to/external
```

To link libraries from `external/lib`, pass a semicolon-separated list:

```bash
cmake -S . -B build -DVIRTUAL_VDP_EXTERNAL_LIBRARIES="vncserver;z"
```
