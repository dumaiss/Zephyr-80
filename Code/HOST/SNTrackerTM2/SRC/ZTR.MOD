IMPLEMENTATION MODULE ZTR;

FROM SYSTEM IMPORT ADR;
FROM Files IMPORT FILE, Open, Close, NoTrailer, ReadBytes, EOF;

CONST
  HeaderSize = 64;
  ZVersion = 4;
  ZHeaderSize = 5;
  ZFlags = 6;
  ZChannels = 7;
  ZTickRate = 8;
  ZSpeed = 10;
  ZSourceChannels = 11;
  ZPatternLength = 12;
  ZOrderCount = 14;
  ZPatternCount = 16;
  ZInstrumentCount = 18;
  ZReserved16 = 22;
  ZPSGClock = 24;
  ZTitleOffset = 28;
  ZOrderOffset = 34;
  ZInstrumentOffset = 36;
  ZMacroOffset = 38;
  ZPatternDirOffset = 40;
  ZPatternDataOffset = 42;
  ZNoteTableOffset = 44;
  ZFileSize = 46;
  ZStringBytes = 48;
  ZOrderBytes = 50;
  ZInstrumentBytes = 51;
  ZPatternBytes = 52;
  ZNoteCount = 53;
  ZReservedStart = 55;

VAR
  data : ARRAY [0..MaxFileSize-1] OF CHAR;
  dataSize : CARDINAL;
  isLoaded : BOOLEAN;
  tickRateValue, speedValue, patternLengthValue : CARDINAL;
  orderCountValue, patternCountValue, instrumentCountValue : CARDINAL;
  orderBase, instrumentBase, macroBase : CARDINAL;
  patternDirBase, patternDataBase, noteTableBase : CARDINAL;

PROCEDURE ByteAt(offset : CARDINAL) : CARDINAL;
BEGIN
  IF offset >= dataSize THEN
    RETURN 0
  END;
  RETURN ORD(data[offset])
END ByteAt;

PROCEDURE WordAt(offset : CARDINAL) : CARDINAL;
BEGIN
  IF (offset >= dataSize) OR (offset + 1 >= dataSize) THEN
    RETURN 0
  END;
  RETURN ORD(data[offset]) + ORD(data[offset + 1]) * 256
END WordAt;

PROCEDURE Has(value, bit : CARDINAL) : BOOLEAN;
BEGIN
  RETURN ((value DIV bit) MOD 2) = 1
END Has;

PROCEDURE RangeOK(first, count, limit : CARDINAL) : BOOLEAN;
BEGIN
  IF first > limit THEN
    RETURN FALSE
  END;
  RETURN count <= limit - first
END RangeOK;

PROCEDURE StringOK(offset, poolStart, poolEnd : CARDINAL) : BOOLEAN;
BEGIN
  IF (offset < poolStart) OR (offset >= poolEnd) THEN
    RETURN FALSE
  END;
  WHILE offset < poolEnd DO
    IF ByteAt(offset) = 0 THEN
      RETURN TRUE
    END;
    INC(offset)
  END;
  RETURN FALSE
END StringOK;

PROCEDURE MacroOK(offset, expectedType : CARDINAL) : BOOLEAN;
VAR count, loopAt, releaseAt, bytes, value : CARDINAL;
BEGIN
  IF offset = 0 THEN
    RETURN TRUE
  END;
  IF (offset < macroBase) OR (offset >= patternDirBase) THEN
    RETURN FALSE
  END;
  IF NOT RangeOK(offset, 12, patternDirBase) THEN
    RETURN FALSE
  END;
  IF ByteAt(offset) # expectedType THEN
    RETURN FALSE
  END;
  IF ByteAt(offset + 1) > 2 THEN
    RETURN FALSE
  END;
  IF ByteAt(offset + 2) > 1 THEN
    RETURN FALSE
  END;
  IF (ByteAt(offset + 3) = 0) OR (ByteAt(offset + 5) # 0) THEN
    RETURN FALSE
  END;
  loopAt := WordAt(offset + 6);
  releaseAt := WordAt(offset + 8);
  count := WordAt(offset + 10);
  IF count = 0 THEN
    RETURN FALSE
  END;
  IF count > (patternDirBase - offset - 12) DIV 3 THEN
    RETURN FALSE
  END;
  bytes := 12 + count * 3;
  IF NOT RangeOK(offset, bytes, patternDirBase) THEN
    RETURN FALSE
  END;
  value := 0;
  WHILE value < count DO
    IF ByteAt(offset + 12 + value * 3) > 1 THEN RETURN FALSE END;
    INC(value)
  END;
  IF (loopAt # 65535) AND (loopAt >= count) THEN
    RETURN FALSE
  END;
  IF (releaseAt # 65535) AND (releaseAt >= count) THEN
    RETURN FALSE
  END;
  RETURN TRUE
END MacroOK;

PROCEDURE InstrumentsOK(poolStart, poolEnd : CARDINAL) : BOOLEAN;
VAR i, entry, slot, offset : CARDINAL;
BEGIN
  i := 0;
  WHILE i < instrumentCountValue DO
    entry := instrumentBase + i * 16;
    IF ByteAt(entry) > 15 THEN RETURN FALSE END;
    IF NOT StringOK(WordAt(entry + 2), poolStart, poolEnd) THEN
      RETURN FALSE
    END;
    slot := 0;
    WHILE slot < 5 DO
      offset := WordAt(entry + 4 + slot * 2);
      IF NOT MacroOK(offset, slot + 1) THEN RETURN FALSE END;
      INC(slot)
    END;
    IF (ByteAt(entry + 14) # 0) OR (ByteAt(entry + 15) # 0) THEN
      RETURN FALSE
    END;
    INC(i)
  END;
  RETURN TRUE
END InstrumentsOK;

PROCEDURE EventStreamOK(offset, length, count : CARDINAL) : BOOLEAN;
VAR pos, finish, seen, row, previous, mask, flags, value : CARDINAL;
BEGIN
  IF NOT RangeOK(offset, length, noteTableBase) THEN RETURN FALSE END;
  finish := offset + length;
  pos := offset;
  seen := 0;
  previous := 256;
  WHILE seen < count DO
    IF NOT RangeOK(pos, 2, finish) THEN RETURN FALSE END;
    row := ByteAt(pos);
    mask := ByteAt(pos + 1);
    INC(pos, 2);
    IF row >= patternLengthValue THEN RETURN FALSE END;
    IF (previous # 256) AND (row <= previous) THEN RETURN FALSE END;
    previous := row;
    IF mask = 0 THEN RETURN FALSE END;
    IF Has(mask, 8) AND (Has(mask, 4) OR Has(mask, 128)) THEN RETURN FALSE END;
    IF Has(mask, 4) AND Has(mask, 128) THEN RETURN FALSE END;
    IF Has(mask, 2) AND NOT Has(mask, 128) THEN RETURN FALSE END;
    IF Has(mask, 128) THEN
      IF NOT RangeOK(pos, 1, finish) THEN RETURN FALSE END;
      IF ByteAt(pos) >= NoteCount THEN RETURN FALSE END;
      INC(pos)
    END;
    IF Has(mask, 64) THEN
      IF NOT RangeOK(pos, 1, finish) THEN RETURN FALSE END;
      IF ByteAt(pos) > 15 THEN RETURN FALSE END;
      INC(pos)
    END;
    IF Has(mask, 32) THEN
      IF NOT RangeOK(pos, 1, finish) THEN RETURN FALSE END;
      IF ByteAt(pos) > 15 THEN RETURN FALSE END;
      INC(pos)
    END;
    IF Has(mask, 16) THEN
      IF NOT RangeOK(pos, 2, finish) THEN RETURN FALSE END;
      IF (ByteAt(pos) = 0) OR (ByteAt(pos) > 6) THEN RETURN FALSE END;
      INC(pos, 2)
    END;
    IF Has(mask, 1) THEN
      IF NOT RangeOK(pos, 1, finish) THEN RETURN FALSE END;
      flags := ByteAt(pos);
      INC(pos);
      IF (flags MOD 8) # 0 THEN RETURN FALSE END;
      IF Has(flags, 64) AND Has(flags, 32) THEN RETURN FALSE END;
      IF Has(flags, 16) AND Has(flags, 8) THEN RETURN FALSE END;
      IF Has(flags, 64) THEN
        IF NOT RangeOK(pos, 1, finish) THEN RETURN FALSE END;
        INC(pos)
      END;
      IF Has(flags, 16) THEN
        IF NOT RangeOK(pos, 2, finish) THEN RETURN FALSE END;
        value := ByteAt(pos);
        IF (value = 0) OR ((value > 15) AND (value < 241)) THEN
          RETURN FALSE
        END;
        IF ByteAt(pos + 1) > 15 THEN RETURN FALSE END;
        INC(pos, 2)
      END
    END;
    INC(seen)
  END;
  RETURN pos = finish
END EventStreamOK;

PROCEDURE PatternsOK() : BOOLEAN;
VAR i, entry, channel, offset, length, count : CARDINAL;
BEGIN
  i := 0;
  WHILE i < patternCountValue DO
    entry := patternDirBase + i * 8;
    channel := ByteAt(entry);
    IF channel >= ChannelCount THEN RETURN FALSE END;
    offset := WordAt(entry + 2);
    length := WordAt(entry + 4);
    count := WordAt(entry + 6);
    IF (offset < patternDataBase) OR (offset > noteTableBase) THEN
      RETURN FALSE
    END;
    IF NOT EventStreamOK(offset, length, count) THEN RETURN FALSE END;
    INC(i)
  END;
  RETURN TRUE
END PatternsOK;

PROCEDURE HeaderOK() : LoadResult;
VAR i, poolStart, poolEnd, stringBytes : CARDINAL;
BEGIN
  IF dataSize < HeaderSize THEN RETURN malformed END;
  IF (ByteAt(0) # ORD('Z')) OR (ByteAt(1) # ORD('T')) OR
     (ByteAt(2) # ORD('R')) OR (ByteAt(3) # ORD('1')) THEN
    RETURN malformed
  END;
  IF (ByteAt(ZVersion) # 1) OR (ByteAt(ZHeaderSize) # HeaderSize) OR
     (ByteAt(ZFlags) # 0) OR (ByteAt(ZChannels) # ChannelCount) THEN
    RETURN unsupported
  END;
  i := ZReservedStart;
  WHILE i < HeaderSize DO
    IF ByteAt(i) # 0 THEN RETURN unsupported END;
    INC(i)
  END;
  IF WordAt(ZReserved16) # 0 THEN RETURN unsupported END;
  IF (ByteAt(ZOrderBytes) # 16) OR
     (ByteAt(ZInstrumentBytes) # 16) OR
     (ByteAt(ZPatternBytes) # 8) OR
     (ByteAt(ZNoteCount) # NoteCount) THEN RETURN unsupported END;
  IF (ByteAt(ZPSGClock) # 153) OR (ByteAt(ZPSGClock + 1) # 158) OR
     (ByteAt(ZPSGClock + 2) # 54) OR (ByteAt(ZPSGClock + 3) # 0) THEN
    RETURN unsupported
  END;

  tickRateValue := WordAt(ZTickRate);
  speedValue := ByteAt(ZSpeed);
  patternLengthValue := WordAt(ZPatternLength);
  orderCountValue := WordAt(ZOrderCount);
  patternCountValue := WordAt(ZPatternCount);
  instrumentCountValue := WordAt(ZInstrumentCount);
  IF (tickRateValue = 0) OR (tickRateValue > 180) OR
     (speedValue = 0) OR (ByteAt(ZSourceChannels) = 0) OR
     (ByteAt(ZSourceChannels) > ChannelCount) OR
     (patternLengthValue = 0) OR (patternLengthValue > 256) OR
     (orderCountValue = 0) OR (orderCountValue > 255) OR
     (instrumentCountValue > 16) THEN RETURN unsupported END;

  IF WordAt(ZFileSize) > MaxFileSize THEN RETURN fileTooLarge END;
  IF (WordAt(ZFileSize) < HeaderSize) OR
     (WordAt(ZFileSize) > dataSize) THEN RETURN malformed END;
  dataSize := WordAt(ZFileSize);
  orderBase := WordAt(ZOrderOffset);
  instrumentBase := WordAt(ZInstrumentOffset);
  macroBase := WordAt(ZMacroOffset);
  patternDirBase := WordAt(ZPatternDirOffset);
  patternDataBase := WordAt(ZPatternDataOffset);
  noteTableBase := WordAt(ZNoteTableOffset);
  stringBytes := WordAt(ZStringBytes);
  poolStart := HeaderSize;
  IF NOT RangeOK(poolStart, stringBytes, dataSize) THEN RETURN malformed END;
  poolEnd := poolStart + stringBytes;
  IF (poolEnd # orderBase) OR
     (orderBase > instrumentBase) OR
     (instrumentBase > macroBase) OR
     (macroBase > patternDirBase) OR
     (patternDirBase > patternDataBase) OR
     (patternDataBase > noteTableBase) THEN RETURN malformed END;
  IF NOT RangeOK(orderBase, orderCountValue * 16, dataSize) THEN
    RETURN malformed
  END;
  IF orderBase + orderCountValue * 16 # instrumentBase THEN
    RETURN malformed
  END;
  IF instrumentBase + instrumentCountValue * 16 # macroBase THEN
    RETURN malformed
  END;
  IF patternCountValue > (dataSize - patternDirBase) DIV 8 THEN
    RETURN malformed
  END;
  IF patternDirBase + patternCountValue * 8 # patternDataBase THEN
    RETURN malformed
  END;
  IF NOT RangeOK(noteTableBase, NoteCount * 2, dataSize) THEN
    RETURN malformed
  END;
  IF noteTableBase + NoteCount * 2 # dataSize THEN RETURN malformed END;
  IF NOT StringOK(WordAt(ZTitleOffset), poolStart, poolEnd) THEN
    RETURN malformed
  END;
  IF NOT StringOK(WordAt(ZTitleOffset + 2), poolStart, poolEnd) THEN
    RETURN malformed
  END;
  IF NOT StringOK(WordAt(ZTitleOffset + 4), poolStart, poolEnd) THEN
    RETURN malformed
  END;
  IF NOT InstrumentsOK(poolStart, poolEnd) THEN RETURN malformed END;
  IF NOT PatternsOK() THEN RETURN malformed END;
  RETURN loadOK
END HeaderOK;

PROCEDURE Load(name : ARRAY OF CHAR) : LoadResult;
VAR file : FILE; fetched : CARDINAL; result : LoadResult;
BEGIN
  isLoaded := FALSE;
  dataSize := MaxFileSize;
  IF (HIGH(name) = 0) OR (name[0] = CHR(0)) THEN RETURN noFileName END;
  IF NOT Open(file, name) THEN RETURN fileNotFound END;
  NoTrailer(file);
  fetched := ReadBytes(file, ADR(data), MaxFileSize);
  IF NOT EOF(file) THEN
    Close(file);
    RETURN fileTooLarge
  END;
  Close(file);
  dataSize := fetched;
  result := HeaderOK();
  isLoaded := result = loadOK;
  RETURN result
END Load;

PROCEDURE Loaded() : BOOLEAN;
BEGIN RETURN isLoaded END Loaded;
PROCEDURE TickRate() : CARDINAL;
BEGIN RETURN tickRateValue END TickRate;
PROCEDURE Speed() : CARDINAL;
BEGIN RETURN speedValue END Speed;
PROCEDURE PatternLength() : CARDINAL;
BEGIN RETURN patternLengthValue END PatternLength;
PROCEDURE OrderCount() : CARDINAL;
BEGIN RETURN orderCountValue END OrderCount;
PROCEDURE PatternCount() : CARDINAL;
BEGIN RETURN patternCountValue END PatternCount;
PROCEDURE InstrumentCount() : CARDINAL;
BEGIN RETURN instrumentCountValue END InstrumentCount;
PROCEDURE FileSize() : CARDINAL;
BEGIN RETURN dataSize END FileSize;

PROCEDURE Title(VAR text : ARRAY OF CHAR);
VAR source, target : CARDINAL;
BEGIN
  source := WordAt(ZTitleOffset);
  target := 0;
  IF HIGH(text) = 0 THEN RETURN END;
  WHILE (target < HIGH(text)) AND (ByteAt(source) # 0) DO
    text[target] := CHR(ByteAt(source));
    INC(target);
    INC(source)
  END;
  text[target] := CHR(0)
END Title;

PROCEDURE OrderPattern(order, channel : CARDINAL) : CARDINAL;
BEGIN
  IF (order >= orderCountValue) OR (channel >= ChannelCount) THEN
    RETURN NoPattern
  END;
  RETURN ByteAt(orderBase + order * 16 + channel)
END OrderPattern;

PROCEDURE FindPattern(channel, pattern : CARDINAL;
                      VAR streamOffset, streamLength : CARDINAL) : BOOLEAN;
VAR i, entry : CARDINAL;
BEGIN
  i := 0;
  WHILE i < patternCountValue DO
    entry := patternDirBase + i * 8;
    IF (ByteAt(entry) = channel) AND (ByteAt(entry + 1) = pattern) THEN
      streamOffset := WordAt(entry + 2);
      streamLength := WordAt(entry + 4);
      RETURN TRUE
    END;
    INC(i)
  END;
  streamOffset := 0;
  streamLength := 0;
  RETURN FALSE
END FindPattern;

PROCEDURE FindInstrument(number : CARDINAL;
                         VAR entryOffset : CARDINAL) : BOOLEAN;
VAR i, entry : CARDINAL;
BEGIN
  i := 0;
  WHILE i < instrumentCountValue DO
    entry := instrumentBase + i * 16;
    IF ByteAt(entry) = number THEN
      entryOffset := entry;
      RETURN TRUE
    END;
    INC(i)
  END;
  entryOffset := 0;
  RETURN FALSE
END FindInstrument;

PROCEDURE NotePeriod(note : CARDINAL) : CARDINAL;
BEGIN
  IF note >= NoteCount THEN note := NoteCount - 1 END;
  RETURN WordAt(noteTableBase + note * 2)
END NotePeriod;

BEGIN
  isLoaded := FALSE;
  dataSize := 0
END ZTR.
