IMPLEMENTATION MODULE Player;

IMPORT ZTR, Sound;

CONST
  EventNote = 128;
  EventInstrument = 64;
  EventVolume = 32;
  EventEffect = 16;
  EventOff = 8;
  EventRelease = 4;
  EventLegato = 2;
  EventModifiers = 1;

  ModReset = 128;
  ModArpSet = 64;
  ModArpClear = 32;
  ModHairpinSet = 16;
  ModHairpinClear = 8;

  EffectArpeggio = 1;
  EffectVolumeSlide = 2;
  EffectLegato = 3;
  EffectVolumeDecrease = 4;
  EffectFastVolume = 5;
  EffectStop = 6;

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
  playingValue, orderChanged : BOOLEAN;
  tickInRow, currentOrder, currentRow : CARDINAL;
  elapsedSubticks, elapsedSeconds, elapsedMinutes : CARDINAL;

PROCEDURE Has(value, bit : CARDINAL) : BOOLEAN;
BEGIN
  RETURN ((value DIV bit) MOD 2) = 1
END Has;

PROCEDURE SignedByte(value : CARDINAL) : INTEGER;
BEGIN
  IF value < 128 THEN RETURN INTEGER(value) END;
  RETURN -INTEGER(255 - value) - 1
END SignedByte;

PROCEDURE SignedWord(value : CARDINAL) : INTEGER;
BEGIN
  IF value < 32768 THEN RETURN INTEGER(value) END;
  RETURN -INTEGER(65535 - value) - 1
END SignedWord;

PROCEDURE MarkPitch(VAR channel : ChannelState);
BEGIN
  channel.dirtyPitch := TRUE;
  channel.dirtyNoise := TRUE
END MarkPitch;

PROCEDURE ClearNotation(VAR channel : ChannelState);
BEGIN
  channel.notationArp := FALSE;
  channel.notationArpParameter := 0;
  channel.notationArpPhase := 0;
  channel.hairpinRate := 0;
  channel.hairpinOffset := 0;
  channel.hairpinCeiling := 0;
  channel.dirtyPitch := TRUE;
  channel.dirtyNoise := TRUE;
  channel.dirtyVolume := TRUE
END ClearNotation;

PROCEDURE ApplyModifiers(VAR channel : ChannelState;
                         flags, arp, hairpinRate,
                         hairpinCeiling : CARDINAL);
BEGIN
  IF Has(flags, ModReset) THEN ClearNotation(channel) END;
  IF Has(flags, ModArpClear) THEN
    channel.notationArp := FALSE;
    channel.notationArpPhase := 0;
    MarkPitch(channel)
  END;
  IF Has(flags, ModArpSet) THEN
    channel.notationArpParameter := arp;
    channel.notationArpPhase := 2;
    channel.notationArp := TRUE;
    MarkPitch(channel)
  END;
  IF Has(flags, ModHairpinClear) THEN channel.hairpinRate := 0 END;
  IF Has(flags, ModHairpinSet) THEN
    channel.hairpinRate := SignedByte(hairpinRate);
    channel.hairpinCeiling := hairpinCeiling
  END
END ApplyModifiers;

PROCEDURE BindInstrument(VAR channel : ChannelState; number : CARDINAL);
VAR entry, slot : CARDINAL;
BEGIN
  slot := 0;
  IF ZTR.FindInstrument(number, entry) THEN
    WHILE slot < 5 DO
      channel.macros[slot].offset := ZTR.WordAt(entry + 4 + slot * 2);
      INC(slot)
    END
  ELSE
    WHILE slot < 5 DO
      channel.macros[slot].offset := 0;
      INC(slot)
    END
  END
END BindInstrument;

PROCEDURE ResetMacros(VAR channel : ChannelState);
VAR slot, offset : CARDINAL;
BEGIN
  slot := 0;
  WHILE slot < 5 DO
    offset := channel.macros[slot].offset;
    channel.macros[slot].position := 0;
    channel.macros[slot].timer := 0;
    IF offset = 0 THEN
      channel.macros[slot].delay := 0
    ELSE
      channel.macros[slot].delay := ZTR.ByteAt(offset + 4)
    END;
    INC(slot)
  END
END ResetMacros;

PROCEDURE ReleaseMacros(VAR channel : ChannelState);
VAR slot, offset, releaseAt : CARDINAL;
BEGIN
  slot := 0;
  WHILE slot < 5 DO
    offset := channel.macros[slot].offset;
    IF (offset # 0) AND Has(ZTR.ByteAt(offset + 2), 1) THEN
      releaseAt := ZTR.WordAt(offset + 8);
      IF releaseAt # 65535 THEN
        channel.macros[slot].position := releaseAt;
        channel.macros[slot].timer := 0;
        channel.macros[slot].delay := 0
      END
    END;
    INC(slot)
  END
END ReleaseMacros;

PROCEDURE NoteOn(VAR channel : ChannelState; note : CARDINAL);
BEGIN
  IF channel.active AND channel.legato THEN
    channel.note := INTEGER(note);
    MarkPitch(channel);
    RETURN
  END;
  channel.note := INTEGER(note);
  channel.active := TRUE;
  channel.released := FALSE;
  channel.macroVolume := 15;
  channel.arpValue := 0;
  channel.pitchValue := 0;
  channel.arpFixed := FALSE;
  channel.dutyValue := 0;
  channel.phaseValue := 0;
  ResetMacros(channel);
  channel.dirtyPitch := TRUE;
  channel.dirtyVolume := TRUE;
  channel.dirtyNoise := TRUE;
  channel.dirtyPhase := TRUE
END NoteOn;

PROCEDURE NoteLegato(VAR channel : ChannelState; note : CARDINAL);
BEGIN
  IF NOT channel.active THEN
    NoteOn(channel, note)
  ELSE
    channel.note := INTEGER(note);
    MarkPitch(channel)
  END
END NoteLegato;

PROCEDURE NoteOff(VAR channel : ChannelState);
BEGIN
  ClearNotation(channel);
  channel.active := FALSE;
  channel.released := FALSE;
  channel.dirtyVolume := TRUE
END NoteOff;

PROCEDURE NoteRelease(VAR channel : ChannelState);
BEGIN
  channel.released := TRUE;
  ReleaseMacros(channel)
END NoteRelease;

PROCEDURE ProcessEffect(VAR channel : ChannelState;
                        effect, parameter : CARDINAL);
VAR amount : CARDINAL;
BEGIN
  IF (effect = EffectArpeggio) OR
     (effect = EffectVolumeSlide) OR
     (effect = EffectFastVolume) THEN
    channel.effect := effect;
    channel.effectParameter := parameter;
    channel.effectPhase := 0;
    MarkPitch(channel)
  ELSIF effect = EffectLegato THEN
    channel.legato := parameter # 0
  ELSIF effect = EffectVolumeDecrease THEN
    amount := parameter;
    IF amount >= channel.baseVolume THEN
      channel.baseVolume := 0
    ELSE
      DEC(channel.baseVolume, amount)
    END;
    channel.dirtyVolume := TRUE
  ELSIF effect = EffectStop THEN
    Stop
  END
END ProcessEffect;

PROCEDURE DecodeChannelRow(VAR channel : ChannelState);
VAR
  pos, mask, note, instrument, volume, effect, parameter : CARDINAL;
  modifierFlags, modifierArp, hairpinRate, hairpinCeiling : CARDINAL;
BEGIN
  pos := channel.patternCursor;
  IF (pos = 0) OR (pos >= channel.patternEnd) THEN RETURN END;
  IF ZTR.ByteAt(pos) # currentRow THEN RETURN END;
  mask := ZTR.ByteAt(pos + 1);
  INC(pos, 2);
  note := 255;
  instrument := 255;
  volume := 255;
  effect := 0;
  parameter := 0;
  modifierFlags := 0;
  modifierArp := 0;
  hairpinRate := 0;
  hairpinCeiling := 0;
  IF Has(mask, EventNote) THEN note := ZTR.ByteAt(pos); INC(pos) END;
  IF Has(mask, EventInstrument) THEN
    instrument := ZTR.ByteAt(pos); INC(pos)
  END;
  IF Has(mask, EventVolume) THEN volume := ZTR.ByteAt(pos); INC(pos) END;
  IF Has(mask, EventEffect) THEN
    effect := ZTR.ByteAt(pos);
    parameter := ZTR.ByteAt(pos + 1);
    INC(pos, 2)
  END;
  IF Has(mask, EventModifiers) THEN
    modifierFlags := ZTR.ByteAt(pos); INC(pos);
    IF Has(modifierFlags, ModArpSet) THEN
      modifierArp := ZTR.ByteAt(pos); INC(pos)
    END;
    IF Has(modifierFlags, ModHairpinSet) THEN
      hairpinRate := ZTR.ByteAt(pos);
      hairpinCeiling := ZTR.ByteAt(pos + 1);
      INC(pos, 2)
    END
  END;
  channel.patternCursor := pos;

  IF Has(mask, EventModifiers) THEN
    ApplyModifiers(channel, modifierFlags, modifierArp,
                   hairpinRate, hairpinCeiling)
  END;
  IF instrument # 255 THEN
    channel.instrument := INTEGER(instrument);
    BindInstrument(channel, instrument)
  END;
  IF volume # 255 THEN
    IF channel.baseVolume # volume THEN
      channel.baseVolume := volume;
      channel.dirtyVolume := TRUE
    END
  END;
  IF effect # 0 THEN ProcessEffect(channel, effect, parameter) END;
  IF Has(mask, EventOff) THEN
    NoteOff(channel)
  ELSIF Has(mask, EventRelease) THEN
    NoteRelease(channel)
  ELSIF note # 255 THEN
    IF Has(mask, EventLegato) THEN
      NoteLegato(channel, note)
    ELSE
      NoteOn(channel, note)
    END
  END
END DecodeChannelRow;

PROCEDURE SetupOrder;
VAR channel, pattern, offset, length : CARDINAL;
BEGIN
  channel := 0;
  WHILE channel < 16 DO
    pattern := ZTR.OrderPattern(currentOrder, channel);
    IF (pattern # ZTR.NoPattern) AND
       ZTR.FindPattern(channel, pattern, offset, length) THEN
      channels[channel].patternCursor := offset;
      channels[channel].patternEnd := offset + length
    ELSE
      channels[channel].patternCursor := 0;
      channels[channel].patternEnd := 0
    END;
    INC(channel)
  END
END SetupOrder;

PROCEDURE BeginRow;
VAR channel : CARDINAL;
BEGIN
  channel := 0;
  WHILE channel < 16 DO
    IF channels[channel].effect = EffectArpeggio THEN
      MarkPitch(channels[channel])
    END;
    channels[channel].effect := 0;
    channels[channel].effectPhase := 0;
    INC(channel)
  END;
  channel := 0;
  WHILE (channel < 16) AND playingValue DO
    DecodeChannelRow(channels[channel]);
    INC(channel)
  END
END BeginRow;

PROCEDURE AdvanceNotation(VAR channel : ChannelState);
VAR next : INTEGER;
BEGIN
  IF channel.notationArp THEN
    INC(channel.notationArpPhase);
    IF channel.notationArpPhase >= 3 THEN channel.notationArpPhase := 0 END;
    MarkPitch(channel)
  END;
  IF channel.hairpinRate # 0 THEN
    next := channel.hairpinOffset + channel.hairpinRate;
    IF next > 15 THEN next := 15 END;
    IF next < -15 THEN next := -15 END;
    IF next # channel.hairpinOffset THEN
      channel.hairpinOffset := next;
      channel.dirtyVolume := TRUE
    END
  END
END AdvanceNotation;

PROCEDURE AdvanceEffects;
VAR channel, amount : CARDINAL; oldVolume : CARDINAL;
BEGIN
  channel := 0;
  WHILE channel < 16 DO
    IF (channels[channel].effect = EffectArpeggio) AND (tickInRow # 0) THEN
      INC(channels[channel].effectPhase);
      IF channels[channel].effectPhase >= 3 THEN
        channels[channel].effectPhase := 0
      END;
      MarkPitch(channels[channel])
    ELSIF ((channels[channel].effect = EffectVolumeSlide) OR
           (channels[channel].effect = EffectFastVolume)) AND
          (tickInRow # 0) THEN
      oldVolume := channels[channel].baseVolume;
      amount := channels[channel].effectParameter DIV 16;
      IF amount # 0 THEN
        IF channels[channel].effect = EffectFastVolume THEN
          amount := amount * 4
        END;
        IF amount + oldVolume > 15 THEN
          channels[channel].baseVolume := 15
        ELSE
          channels[channel].baseVolume := oldVolume + amount
        END
      ELSE
        amount := channels[channel].effectParameter MOD 16;
        IF channels[channel].effect = EffectFastVolume THEN
          amount := amount * 4
        END;
        IF amount >= oldVolume THEN
          channels[channel].baseVolume := 0
        ELSE
          channels[channel].baseVolume := oldVolume - amount
        END
      END;
      IF channels[channel].baseVolume # oldVolume THEN
        channels[channel].dirtyVolume := TRUE
      END
    END;
    AdvanceNotation(channels[channel]);
    INC(channel)
  END
END AdvanceEffects;

PROCEDURE BoundMacro(VAR macro : MacroState; released : BOOLEAN);
VAR count, loopAt, releaseAt : CARDINAL;
BEGIN
  count := ZTR.WordAt(macro.offset + 10);
  loopAt := ZTR.WordAt(macro.offset + 6);
  releaseAt := ZTR.WordAt(macro.offset + 8);
  IF (NOT released) AND (releaseAt # 65535) AND
     (macro.position >= releaseAt) THEN
    IF loopAt # 65535 THEN
      macro.position := loopAt
    ELSIF releaseAt = 0 THEN
      macro.position := 0
    ELSE
      macro.position := releaseAt - 1
    END
  END;
  IF macro.position >= count THEN
    IF released AND (releaseAt # 65535) THEN
      macro.position := count - 1
    ELSIF loopAt # 65535 THEN
      macro.position := loopAt
    ELSE
      macro.position := count - 1
    END
  END
END BoundMacro;

PROCEDURE ApplyMacro(VAR channel : ChannelState;
                     slot, flags : CARDINAL; value : INTEGER);
VAR unsigned : CARDINAL;
BEGIN
  IF slot = 0 THEN
    IF value < 0 THEN unsigned := 0 ELSE unsigned := CARDINAL(value) END;
    IF unsigned > 15 THEN unsigned := 15 END;
    IF channel.macroVolume # unsigned THEN
      channel.macroVolume := unsigned;
      channel.dirtyVolume := TRUE
    END
  ELSIF slot = 1 THEN
    IF channel.pitchValue # value THEN
      channel.pitchValue := value;
      channel.dirtyPitch := TRUE
    END
  ELSIF slot = 2 THEN
    IF (channel.arpValue # value) OR
       (channel.arpFixed # Has(flags, 1)) THEN
      channel.arpValue := value;
      channel.arpFixed := Has(flags, 1);
      MarkPitch(channel)
    END
  ELSIF slot = 3 THEN
    IF value < 0 THEN unsigned := 0 ELSE unsigned := CARDINAL(value) END;
    unsigned := unsigned MOD 2;
    IF channel.dutyValue # unsigned THEN
      channel.dutyValue := unsigned;
      channel.dirtyNoise := TRUE
    END
  ELSE
    IF value < 0 THEN unsigned := 0 ELSE unsigned := CARDINAL(value) END;
    channel.phaseValue := unsigned;
    IF (unsigned # 0) THEN channel.dirtyPhase := TRUE END
  END
END ApplyMacro;

PROCEDURE AdvanceMacro(VAR channel : ChannelState; slot : CARDINAL);
VAR offset, address, flags, step : CARDINAL; value : INTEGER;
BEGIN
  offset := channel.macros[slot].offset;
  IF offset = 0 THEN RETURN END;
  IF channel.macros[slot].delay # 0 THEN
    DEC(channel.macros[slot].delay);
    RETURN
  END;
  IF channel.macros[slot].timer # 0 THEN
    DEC(channel.macros[slot].timer);
    RETURN
  END;
  BoundMacro(channel.macros[slot], channel.released);
  address := offset + 12 + channel.macros[slot].position * 3;
  flags := ZTR.ByteAt(address);
  value := SignedWord(ZTR.WordAt(address + 1));
  step := ZTR.ByteAt(offset + 3);
  IF step > 0 THEN DEC(step) END;
  channel.macros[slot].timer := step;
  INC(channel.macros[slot].position);
  BoundMacro(channel.macros[slot], channel.released);
  ApplyMacro(channel, slot, flags, value)
END AdvanceMacro;

PROCEDURE AdvanceMacros;
VAR channel, slot : CARDINAL;
BEGIN
  channel := 0;
  WHILE channel < 16 DO
    IF channels[channel].active THEN
      slot := 0;
      WHILE slot < 5 DO
        AdvanceMacro(channels[channel], slot);
        INC(slot)
      END
    END;
    INC(channel)
  END
END AdvanceMacros;

PROCEDURE EffectiveNote(VAR channel : ChannelState) : CARDINAL;
VAR note, offset : INTEGER; phase : CARDINAL;
BEGIN
  IF channel.arpFixed THEN
    note := channel.arpValue
  ELSE
    note := channel.note + channel.arpValue
  END;
  IF channel.effect = EffectArpeggio THEN
    phase := channel.effectPhase;
    IF phase = 1 THEN
      offset := INTEGER(channel.effectParameter DIV 16)
    ELSIF phase = 2 THEN
      offset := INTEGER(channel.effectParameter MOD 16)
    ELSE
      offset := 0
    END;
    note := note + offset
  END;
  IF channel.notationArp THEN
    phase := channel.notationArpPhase;
    IF phase = 1 THEN
      offset := INTEGER(channel.notationArpParameter DIV 16)
    ELSIF phase = 2 THEN
      offset := INTEGER(channel.notationArpParameter MOD 16)
    ELSE
      offset := 0
    END;
    note := note + offset
  END;
  IF note < 0 THEN RETURN 0 END;
  IF note >= ZTR.NoteCount THEN RETURN ZTR.NoteCount - 1 END;
  RETURN CARDINAL(note)
END EffectiveNote;

PROCEDURE ToneValue(VAR channel : ChannelState) : CARDINAL;
VAR period, magnitude, delta : CARDINAL; pitch : INTEGER;
BEGIN
  period := ZTR.NotePeriod(EffectiveNote(channel));
  pitch := channel.pitchValue;
  IF pitch = 0 THEN RETURN period END;
  IF pitch < 0 THEN magnitude := CARDINAL(-pitch)
  ELSE magnitude := CARDINAL(pitch)
  END;
  IF magnitude > 63 THEN magnitude := 63 END;
  delta := (period * magnitude) DIV 2048;
  IF pitch < 0 THEN
    IF period + delta > 1023 THEN RETURN 1023 END;
    RETURN period + delta
  END;
  IF delta >= period THEN RETURN 1 END;
  RETURN period - delta
END ToneValue;

PROCEDURE Loudness(VAR channel : ChannelState) : CARDINAL;
VAR volume : INTEGER;
BEGIN
  IF NOT channel.active THEN RETURN 0 END;
  volume := INTEGER((channel.baseVolume * channel.macroVolume) DIV 15);
  volume := volume + channel.hairpinOffset;
  IF volume < 0 THEN RETURN 0 END;
  IF (channel.hairpinOffset > 0) AND
     (volume > INTEGER(channel.hairpinCeiling)) THEN
    RETURN channel.hairpinCeiling
  END;
  RETURN CARDINAL(volume)
END Loudness;

PROCEDURE Render;
VAR
  number, rate : CARDINAL;
  result : Sound.Result;
  mode : Sound.NoiseMode;
BEGIN
  number := 0;
  WHILE number < 16 DO
    IF (number MOD 4) = 3 THEN
      IF channels[number].dirtyPitch OR channels[number].dirtyNoise OR
         channels[number].dirtyPhase THEN
        rate := EffectiveNote(channels[number]) MOD 4;
        IF channels[number].dutyValue = 0 THEN
          mode := Sound.periodicNoise
        ELSE
          mode := Sound.whiteNoise
        END;
        result := Sound.SetNoise(Sound.Channel(number), mode,
                                 Sound.NoiseRate(rate));
        channels[number].dirtyPitch := FALSE;
        channels[number].dirtyNoise := FALSE;
        channels[number].dirtyPhase := FALSE
      END
    ELSIF channels[number].dirtyPitch THEN
      result := Sound.SetTone(Sound.Channel(number),
                              Sound.TonePeriod(ToneValue(channels[number])));
      channels[number].dirtyPitch := FALSE
    END;
    IF (number MOD 4) # 3 THEN channels[number].dirtyPhase := FALSE END;
    IF channels[number].dirtyVolume THEN
      Sound.SetVolume(Sound.Channel(number),
                      Sound.Volume(Loudness(channels[number])));
      channels[number].dirtyVolume := FALSE
    END;
    INC(number)
  END
END Render;

PROCEDURE AdvanceClock;
BEGIN
  INC(elapsedSubticks);
  IF elapsedSubticks >= ZTR.TickRate() THEN
    elapsedSubticks := 0;
    INC(elapsedSeconds);
    IF elapsedSeconds >= 60 THEN
      elapsedSeconds := 0;
      INC(elapsedMinutes);
      IF elapsedMinutes >= 100 THEN elapsedMinutes := 0 END
    END
  END
END AdvanceClock;

PROCEDURE AdvancePosition;
BEGIN
  INC(currentRow);
  IF currentRow >= ZTR.PatternLength() THEN
    currentRow := 0;
    INC(currentOrder);
    IF currentOrder >= ZTR.OrderCount() THEN
      Stop
    ELSE
      orderChanged := TRUE;
      SetupOrder
    END
  END
END AdvancePosition;

PROCEDURE Init;
VAR number, slot : CARDINAL;
BEGIN
  number := 0;
  WHILE number < 16 DO
    WITH channels[number] DO
      (* Assembly initializes the raw note byte to FFh; its clamp therefore
         renders inactive voices at note 95 before writing volume zero. *)
      note := 95;
      instrument := -1;
      baseVolume := 15;
      macroVolume := 15;
      effect := 0;
      effectParameter := 0;
      effectPhase := 0;
      active := FALSE;
      released := FALSE;
      legato := FALSE;
      dirtyPitch := TRUE;
      dirtyVolume := TRUE;
      dirtyNoise := TRUE;
      dirtyPhase := TRUE;
      arpValue := 0;
      pitchValue := 0;
      arpFixed := FALSE;
      dutyValue := 0;
      phaseValue := 0;
      patternCursor := 0;
      patternEnd := 0;
      notationArp := FALSE;
      notationArpParameter := 0;
      notationArpPhase := 0;
      hairpinRate := 0;
      hairpinOffset := 0;
      hairpinCeiling := 15
    END;
    slot := 0;
    WHILE slot < 5 DO
      channels[number].macros[slot].offset := 0;
      channels[number].macros[slot].position := 0;
      channels[number].macros[slot].timer := 0;
      channels[number].macros[slot].delay := 0;
      INC(slot)
    END;
    INC(number)
  END;
  playingValue := FALSE;
  orderChanged := FALSE
END Init;

PROCEDURE Start;
BEGIN
  Init;
  currentOrder := 0;
  currentRow := 0;
  tickInRow := 0;
  elapsedSubticks := 0;
  elapsedSeconds := 0;
  elapsedMinutes := 0;
  SetupOrder;
  Sound.MuteAll;
  playingValue := TRUE;
  orderChanged := TRUE
END Start;

PROCEDURE Stop;
BEGIN
  playingValue := FALSE;
  Sound.MuteAll
END Stop;

PROCEDURE Tick;
BEGIN
  IF NOT playingValue THEN RETURN END;
  IF tickInRow = 0 THEN BeginRow END;
  IF NOT playingValue THEN RETURN END;
  AdvanceEffects;
  AdvanceMacros;
  Render;
  AdvanceClock;
  INC(tickInRow);
  IF tickInRow >= ZTR.Speed() THEN
    tickInRow := 0;
    AdvancePosition
  END
END Tick;

PROCEDURE Playing() : BOOLEAN;
BEGIN RETURN playingValue END Playing;
PROCEDURE CurrentOrder() : CARDINAL;
BEGIN RETURN currentOrder END CurrentOrder;
PROCEDURE CurrentRow() : CARDINAL;
BEGIN RETURN currentRow END CurrentRow;
PROCEDURE Minutes() : CARDINAL;
BEGIN RETURN elapsedMinutes END Minutes;
PROCEDURE Seconds() : CARDINAL;
BEGIN RETURN elapsedSeconds END Seconds;
PROCEDURE TakeOrderChange() : BOOLEAN;
VAR changed : BOOLEAN;
BEGIN
  changed := orderChanged;
  orderChanged := FALSE;
  RETURN changed
END TakeOrderChange;

BEGIN
  playingValue := FALSE;
  orderChanged := FALSE
END Player.
