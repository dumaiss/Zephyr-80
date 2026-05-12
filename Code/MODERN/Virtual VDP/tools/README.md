# Tools

## `serial_replay.py`

Streams a Virtual Drip binary packet file to a serial device. Packet bytes are
written exactly as stored in the file, one complete packet at a time. The tool
detects `FRAME_MARK` packets and pauses after each one so animation fixtures can
be observed through the proxy's serial input path.

Examples:

```bash
python3 tools/serial_replay.py tests/sprite-moving.bin --port /dev/ttyUSB0 --baud 1000000 --frame-delay-ms 16.67 --verbose
python3 tools/serial_replay.py tests/sprite-moving.bin --port /dev/pts/5 --baud 115200 --loop
python3 tools/serial_replay.py tests/sprite-moving.bin --port /dev/pts/5 --baud 115200 --loop --read-back --verbose
python3 tools/serial_replay.py tests/sprite-moving.bin --dry-run --verbose
```

Serial mode requires `pyserial`:

```bash
python3 -m pip install pyserial
```
