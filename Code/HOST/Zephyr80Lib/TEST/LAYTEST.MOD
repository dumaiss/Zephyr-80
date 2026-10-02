MODULE LayTest;

(* Reports the byte offsets FTL assigns to ChannelState's fields, and the
   stride of the channels array.  An assembly port has to hardcode these, so
   they must be measured rather than assumed from the declaration order. *)

FROM SYSTEM IMPORT ADR, ADDRESS, TSIZE;
FROM PortIO IMPORT Out;

CONST Mark = 253;

TYPE
  MacroState = RECORD
    offset, position, timer, delay : CARDINAL;
  END;

  ChannelState = RECORD
    note, instrument : INTEGER;
    baseVolume, macroVolume : CARDINAL;
    effect, effectParameter, effectPhase : CARDINAL;
    active, released, legato : BOOLEAN;
    dirtyPitch, dirtyVolume, dirtyNoise, dirtyPhase : BOOLEAN;
    arpValue, pitchValue : INTEGER;
    arpFixed : BOOLEAN;
    dutyValue, phaseValue : CARDINAL;
    macros : ARRAY [0..4] OF MacroState;
    patternCursor, patternEnd : CARDINAL;
    notationArp : BOOLEAN;
    notationArpParameter, notationArpPhase : CARDINAL;
    hairpinRate, hairpinOffset : INTEGER;
    hairpinCeiling : CARDINAL;
  END;

VAR
  channels : ARRAY [0..15] OF ChannelState;
  base : CARDINAL;

PROCEDURE Emit(a : ADDRESS);
BEGIN
  Out(Mark, CARDINAL(a) - base)
END Emit;

BEGIN
  base := CARDINAL(ADR(channels[0]));
  Out(252, TSIZE(ChannelState));
  Out(252, TSIZE(MacroState));
  Out(251, CARDINAL(ADR(channels[1])) - base);   (* array stride *)
  Emit(ADR(channels[0].note));
  Emit(ADR(channels[0].instrument));
  Emit(ADR(channels[0].baseVolume));
  Emit(ADR(channels[0].macroVolume));
  Emit(ADR(channels[0].effect));
  Emit(ADR(channels[0].effectParameter));
  Emit(ADR(channels[0].effectPhase));
  Emit(ADR(channels[0].active));
  Emit(ADR(channels[0].released));
  Emit(ADR(channels[0].legato));
  Emit(ADR(channels[0].dirtyPitch));
  Emit(ADR(channels[0].dirtyVolume));
  Emit(ADR(channels[0].dirtyNoise));
  Emit(ADR(channels[0].dirtyPhase));
  Emit(ADR(channels[0].arpValue));
  Emit(ADR(channels[0].pitchValue));
  Emit(ADR(channels[0].arpFixed));
  Emit(ADR(channels[0].dutyValue));
  Emit(ADR(channels[0].phaseValue));
  Emit(ADR(channels[0].macros[0]));
  Emit(ADR(channels[0].macros[1]));
  Emit(ADR(channels[0].patternCursor));
  Emit(ADR(channels[0].patternEnd));
  Emit(ADR(channels[0].notationArp));
  Emit(ADR(channels[0].notationArpParameter));
  Emit(ADR(channels[0].notationArpPhase));
  Emit(ADR(channels[0].hairpinRate));
  Emit(ADR(channels[0].hairpinOffset));
  Emit(ADR(channels[0].hairpinCeiling))
END LayTest.
