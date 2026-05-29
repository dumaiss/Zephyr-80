; Virtual Drip wire protocol constants for Z80-side code.
;
; Packets are encoded as:
;   A5h 5Ah LEN TYPE PAYLOAD... CRC8
;
; LEN counts LEN, TYPE, PAYLOAD, and CRC8. CRC8 covers LEN, TYPE, and
; PAYLOAD only. Cursor commands are proxy/display overlay commands; they do
; not write emulated VDP memory or registers.

PACKET_SYNC0            EQU     0A5H
PACKET_SYNC1            EQU     05AH

PACKET_VDP_CTRL_WRITE   EQU     001H
PACKET_VDP_DATA_WRITE   EQU     002H
PACKET_VDP_STATUS_READ  EQU     003H
PACKET_VDP_DATA_READ    EQU     004H
PACKET_KEY_EVENT        EQU     005H
PACKET_RESET            EQU     006H
PACKET_PING             EQU     007H
PACKET_FRAME_MARK       EQU     008H
PACKET_CURSOR_COMMAND   EQU     009H

CURSOR_ENABLE           EQU     001H
CURSOR_SHOW             EQU     002H
CURSOR_HIDE             EQU     003H
CURSOR_SET_POSITION     EQU     004H
CURSOR_MOVE_RELATIVE    EQU     005H
CURSOR_SET_STYLE        EQU     006H
CURSOR_SET_BLINK        EQU     007H
CURSOR_SET_COLOR        EQU     008H
CURSOR_SET_GEOMETRY     EQU     009H

CURSOR_STYLE_BLOCK      EQU     000H
CURSOR_STYLE_UNDERLINE  EQU     001H
CURSOR_STYLE_LEFT_BAR   EQU     002H
