{******************************************************************************}
{*                                                                            *}
{* DDevExtensions                                                             *}
{*                                                                            *}
{* (C) 2006-2011 Andreas Hausladen                                            *}
{*                                                                            *}
{******************************************************************************}

unit DisableAlphaSortClassCompletion;

{$I ..\DelphiExtension.inc}

interface

procedure InstallDisableAlphaSortClassCompletion(Value: Boolean);

implementation

{$IF CompilerVersion < 20.0} // mirrors 2009+ compiler internals; not available on D7
procedure InstallDisableAlphaSortClassCompletion(Value: Boolean);
begin
end;
{$ELSE}

uses
  Windows, SysUtils, Classes, TypInfo, Hooking, IDEHooks;

type
  TClassSymbol = class
  end;

  TBaseSymbol = class(TObject)
  public
    Next: TBaseSymbol;
    FShortIdent: ShortString;    //UTF8-encoded data
    FIdent: UnicodeString;
  end;

  TSymbolTable = class(TObject)
  private
    FCount: Integer;
    FSymbolList: array[0..31] of TBaseSymbol;
    //FCompare: TCompareSymbols;
  public
    property Count: Integer read FCount;
  end;

  TTableIterator = class
  protected
    FxxxLocation: Integer;
    FxxxIndex: Integer;
    FxxxSymbol: TBaseSymbol;
    FCount: Integer; // FCount must be at this offset

    FSymbols: array of TBaseSymbol;

    function GetSymbol(Index: Integer): TBaseSymbol;
    procedure LoadSymbols(Table: TSymbolTable);
    procedure QuickSort(L, R: Integer);
  public
    constructor Create(Table: TSymbolTable);
    property Count: Integer read FCount;
    property Symbols[Index: Integer]: TBaseSymbol read GetSymbol; default;
  end;

  TMethodSymbol = class;

  TAccess = (saDefault, saStrictPrivate, saPrivate, saStrictProtected, saProtected, saPublic, saPublished, saAutomated);

  TMethodSignature = class
  public
    MethodSymbol: TMethodSymbol;
    TypeData: PTypeData;
    TypeSize: Word;
    Empty: Boolean;
    HeaderPos, HeaderNamePos, HeaderEnd, HeaderLineEnd: LongInt;
    CodePos, CodeNamePos, CodeHeaderEnd, CodeBegin, CodeEnd, CodeStatement: LongInt;
    ImplHeaderEnd, ImplEnd: LongInt;
    BeginPos: LongInt;
    Access: TAccess;
    DispidPos, DispidEnd: LongInt;
    Next: TMethodSignature;
    InterfaceMethod: Boolean;
    NestedProcedures: TSymbolTable;

    function IsImplemented: Boolean;
    function GetTypeSortId: Integer;
  end;

  TMethodSymbol = class(TBaseSymbol)
  public
    FMethodSignature: TMethodSignature;
  end;

var
  OrgTClassSymbol_MethodAddPos: function(Instance: TClassSymbol; const Name: string): Integer;
  OrgTSortedThingList_SetSorted: Pointer;
  OrgTTableIterator_Ctor: Pointer;
  OrgTTableIterator_GetSymbol: Pointer;

  CallAddrTSortedThingList_SetSortedP: PByte;
  CompleteMethodSymbolTableIteratorP: PByte;

{$IFNDEF CPUX64}
function TClassSymbol_MethodAddPos(Instance: TClassSymbol; const Name: string): Integer;
  external delphicoreide_bpl name '@Pasmgr@TClassSymbol@MethodAddPos$qqrx20System@UnicodeString';
{$ENDIF}
{$IFDEF CPUX64}
function TClassSymbol_MethodAddPos(Instance: TClassSymbol; const Name: string): Integer;
  external delphicoreide_bpl name '_ZN6Pasmgr12TClassSymbol12MethodAddPosEN6System13UnicodeStringE';
{$ENDIF}

{$IFNDEF CPUX64}
procedure TPascalClassCompleter_Complete;
  external delphicoreide_bpl name '@Completers@TPascalClassCompleter@Complete$qqrx20System@UnicodeString';
{$ENDIF}
{$IFDEF CPUX64}
procedure TPascalClassCompleter_Complete;
  external delphicoreide_bpl name '_ZN10Completers21TPascalClassCompleter8CompleteEN6System13UnicodeStringE';
{$ENDIF}

function TClassSymbol_MethodAddPos_AlphSort(Instance: TClassSymbol; const Name: string): Integer;
begin
  Result := OrgTClassSymbol_MethodAddPos(Instance, '');
end;

procedure TSortedThingList_SetSorted(Instance: TObject; Value: Boolean);
begin
  // don't sort the list, the TTableIterator already did that
end;

{ TTableIterator }

constructor TTableIterator.Create(Table: TSymbolTable);
begin
  inherited Create;
  if Table <> nil then
    LoadSymbols(Table);
end;

procedure TTableIterator.LoadSymbols(Table: TSymbolTable);
var
  Index: Integer;
  Symbol: TBaseSymbol;
  Location: Integer;
begin
  FCount := Table.Count;
  SetLength(FSymbols, FCount);

  Index := 0;
  for Location := 0 to Length(Table.FSymbolList) - 1 do
  begin
    Symbol := Table.FSymbolList[Location];
    if Symbol <> nil then
    begin
      repeat
        FSymbols[Index] := Symbol;
        Inc(Index);
        Symbol := Symbol.Next;
      until Symbol = nil;
      if Index >= FCount then
        Break;
    end;
  end;

  if Count > 0 then
    QuickSort(0, Count - 1);
end;

function TTableIterator.GetSymbol(Index: Integer): TBaseSymbol;
begin
  Result := FSymbols[Index];
end;


function CompareInt(V1, V2: Integer): Integer; inline;
begin
  if V1 = V2 then
    Result := 0
  else if V1 > V2 then
    Result := 1
  else
    Result := -1;
end;

function CompareSymbol(Sym1, Sym2: TBaseSymbol): Integer;
var
  M1, M2: TMethodSymbol;
  Id1, Id2: Integer;
  HP1, HP2: Integer;
begin
  if Sym1 <> Sym2 then
  begin
    M1 := TMethodSymbol(Sym1);
    M2 := TMethodSymbol(Sym2);
    Id1 := M1.FMethodSignature.GetTypeSortId;
    Id2 := M2.FMethodSignature.GetTypeSortId;

    if Id1 = Id2 then
    begin
      HP1 := M1.FMethodSignature.HeaderPos;
      HP2 := M2.FMethodSignature.HeaderPos;
      if (HP1 = 0) and (HP2 = 0) then
        Result := CompareInt(M1.FMethodSignature.CodePos, M2.FMethodSignature.CodePos)
      else
        Result := CompareInt(HP1, HP2);
    end
    else if Id1 > Id2 then
      Result := 1
    else
      Result := -1;
  end
  else
    Result := 0;
end;

procedure TTableIterator.QuickSort(L, R: Integer);
var
  I, J: Integer;
  P, T: TBaseSymbol;
begin
  repeat
    I := L;
    J := R;
    P := FSymbols[(L + R) shr 1];
    repeat
      while CompareSymbol(FSymbols[I], P) < 0 do
        Inc(I);
      while CompareSymbol(FSymbols[J], P) > 0 do
        Dec(J);
      if I <= J then
      begin
        if I <> J then
        begin
          T := FSymbols[I];
          FSymbols[I] := FSymbols[J];
          FSymbols[J] := T;
        end;
        Inc(I);
        Dec(J);
      end;
    until I > J;
    if L < J then
      QuickSort(L, J);
    L := I;
  until I >= R;
end;

{ TMethodSignature }

function TMethodSignature.IsImplemented: Boolean;
begin
  Result := (CodePos <> 0) and (TypeData <> nil);
end;

function TMethodSignature.GetTypeSortId: Integer;
begin
  Result := 100;
  if TypeData <> nil then
  begin
    case TypeData.MethodKind of
      mkClassConstructor:
        Result := 0;
      {$IF CompilerVersion >= 21.0} // 2010+
      mkClassDestructor:
        Result := 1;
      {$IFEND}
      mkConstructor:
        Result := 2;
      mkDestructor:
        Result := 3;
//      mkClassProcedure, mkClassFunction:
//        Result := 4;
      mkOperatorOverload:
        Result := 200;
    end;
  end;
end;

{-------------------------------------------------------------------------------------------------}

function TTableIterator_Create(ASymbolTable: TSymbolTable): TTableIterator;
begin
  Result := TTableIterator.Create(ASymbolTable);
end;

{$IFNDEF CPUX64}
function MethodSymbolTableIteratorFactory(AClass: TClass; DL: Integer; ASymbolTable: TSymbolTable): TTableIterator;
asm
  push ecx

  // Sort all items that are already collected
  mov eax, [ebp-$10] // Thingslist
  mov edx, 1
  call [OrgTSortedThingList_SetSorted]

  // Disable sorting so that the methods can be added in their correct order
// !!! Sorting is implemented wrongly. Disabling sort calls TList.Sort, and as long as nobody calls SetSorted no further sorting is done
//  mov eax, [ebp-$10] // Thingslist
//  xor edx, edx
//  call [OrgTSortedThingList_SetSorted]

  pop eax
  call TTableIterator_Create
end;
{$ELSE}
function MethodSymbolTableIteratorFactory(AClass: TClass; DL: Integer; ASymbolTable: TSymbolTable): TTableIterator;
begin
  // Win64: simplified fallback - just create the iterator without sorting hack
  Result := TTableIterator_Create(ASymbolTable);
end;
{$ENDIF ~CPUX64}
{begin
  // Sort all items that are already collected
  OrgTSortedThingList_SetSorted(ThingList, True);
  // Disable sorting so that the methods can be added in their correct order
  //OrgTSortedThingList_SetSorted(ThingList, False);

  Result := TTableIterator.Create;
end;}

{-------------------------------------------------------------------------------------------------}

{$IFDEF CPUX64}
// ---------------------------------------------------------------------------
//  Delphi 13 x64 — diagnostic-first (step 1). See scratchpad alphasort_x64_RE.md.
//  The x86 byte-pattern patcher does not apply on x64. Here we only install a
//  behavior-neutral pass-through on the Symbols::TTableIterator constructor
//  (imported by delphicoreide370 from designide370) and LOG the real x64 object
//  layouts, scoped via the return address to calls coming from
//  TPascalClassCompleter.Complete only. Goal: derive the true field offsets
//  (TSymbolTable.FCount/FSymbolList, TBaseSymbol.Next, TMethodSignature.*)
//  before the real reordering hook is written. Patches the IAT slot (full
//  64-bit pointer) so there is no rel32 / near-trampoline concern.
// ---------------------------------------------------------------------------
const
  sDsgnTableIteratorCtor = '_ZN7Symbols14TTableIteratorC3EPNS_12TSymbolTableE';

type
  TIteratorCtorProc = function(AClass: Pointer; AllocFlag: NativeInt; ATable: Pointer): Pointer;

var
  DiagCtorIatSlot: PPointer;       // patched IAT slot in delphicoreide370
  DiagOrgCtor: Pointer;            // original designide ctor
  DiagCompleteLo, DiagCompleteHi: NativeUInt;
  DiagLogged: Integer;            // throttle: only the first few completion calls
  DiagSymDumped: Boolean;         // round 2: dump the symbol objects of the first populated table once

procedure DiagLog(const S: string);
var
  F: TextFile;
  Dir, FileName: string;
begin
  try
    Dir := GetEnvironmentVariable('APPDATA') + '\DDevExtensions';
    FileName := Dir + '\AlphaSort.log';
    AssignFile(F, FileName);
    if FileExists(FileName) then Append(F) else Rewrite(F);
    try
      WriteLn(F, S);
    finally
      CloseFile(F);
    end;
  except
    // diagnostics must never break the IDE
  end;
end;

function DiagHexDump(P: Pointer; Len: Integer): string;
var
  i: Integer;
  b: PByte;
  line: string;
begin
  Result := '';
  b := PByte(P);
  i := 0;
  line := '';
  while i < Len do
  begin
    if (i and 15) = 0 then
    begin
      if i > 0 then Result := Result + line + sLineBreak;
      line := Format('  +%3.3x: ', [i]);
    end;
    try
      line := line + IntToHex(b[i], 2) + ' ';
    except
      line := line + '?? ';
    end;
    Inc(i);
  end;
  Result := Result + line;
end;

function DiagReadable(P: Pointer; Len: NativeUInt): Boolean;
var
  mbi: TMemoryBasicInformation;
begin
  Result := False;
  if (P = nil) or (NativeUInt(P) < $10000) then Exit;
  if VirtualQuery(P, mbi, SizeOf(mbi)) = 0 then Exit;
  if mbi.State <> MEM_COMMIT then Exit;
  if (mbi.Protect and (PAGE_NOACCESS or PAGE_GUARD)) <> 0 then Exit;
  // whole range must lie inside this committed region
  Result := NativeUInt(P) + Len <= NativeUInt(mbi.BaseAddress) + NativeUInt(mbi.RegionSize);
end;

// Round 3: TBaseSymbol.Next @ +0x08 and FShortIdent(ShortString) @ +0x10 are
// confirmed. Walk each bucket's Next chain, dump each symbol to 0x160 (so
// FIdent @ +0x110 and FMethodSignature @ +0x118 are visible) and, for the first
// few symbols, chase the +0x108..+0x120 pointer fields to dump the signature
// object (TMethodSignature.HeaderPos/CodePos/TypeData).
procedure DiagDumpTable(ATable: Pointer);
const
  NEXT_OFF = $08;
var
  cnt, i, off, symDumps, sigDumps: Integer;
  head, sym, tgt: Pointer;
begin
  if not DiagReadable(ATable, $10) then Exit;
  cnt := PInteger(PByte(ATable) + 8)^;
  DiagLog(Format('=== populated SymbolTable walk: @%p FCount@+8=%d ===', [ATable, cnt]));
  symDumps := 0;
  sigDumps := 0;
  for i := 0 to 31 do
  begin
    if symDumps >= 40 then Break;
    head := PPointer(PByte(ATable) + $10 + i * 8)^;
    if head = nil then Continue;
    sym := head;
    while (sym <> nil) and DiagReadable(sym, $160) and (symDumps < 40) do
    begin
      DiagLog(Format('sym bucket[%d] @%p:', [i, sym]));
      DiagLog(DiagHexDump(sym, $160));
      Inc(symDumps);
      // chase the FIdent / FMethodSignature region once for the first few symbols
      if sigDumps < 6 then
      begin
        off := $108;
        while off <= $120 do
        begin
          if DiagReadable(PByte(sym) + off, 8) then
          begin
            tgt := PPointer(PByte(sym) + off)^;
            if DiagReadable(tgt, $A0) then
            begin
              DiagLog(Format('  [+%x]->%p (sig/ident?):', [off, tgt]));
              DiagLog(DiagHexDump(tgt, $A0));
              Inc(sigDumps);
            end;
          end;
          Inc(off, 8);
        end;
      end;
      sym := PPointer(PByte(sym) + NEXT_OFF)^;   // follow Next chain
    end;
  end;
end;

function DiagIteratorCtor(AClass: Pointer; AllocFlag: NativeInt; ATable: Pointer): Pointer;
var
  Org: TIteratorCtorProc;
  ra: NativeUInt;
  inComplete: Boolean;
begin
  Org := TIteratorCtorProc(DiagOrgCtor);
  Result := Org(AClass, AllocFlag, ATable);   // behavior-neutral: real ctor runs unchanged

  ra := NativeUInt(ReturnAddress);
  inComplete := (ra >= DiagCompleteLo) and (ra < DiagCompleteHi);
  if not inComplete then
    Exit;

  if DiagLogged < 4 then
  begin
    Inc(DiagLogged);
    try
      DiagLog('--- TTableIterator ctor from Complete, call #' + IntToStr(DiagLogged) + ' ---');
      DiagLog(Format('  ret=%p AClass=%p AllocFlag=%d ATable=%p Iterator=%p',
        [Pointer(ra), AClass, AllocFlag, ATable, Result]));
      if ATable <> nil then
      begin
        DiagLog('  SymbolTable dump (0x140 bytes):');
        DiagLog(DiagHexDump(ATable, $140));
      end;
      if Result <> nil then
      begin
        DiagLog('  Iterator dump (0x40 bytes):');
        DiagLog(DiagHexDump(Result, $40));
      end;
    except
      DiagLog('  (exception during dump)');
    end;
  end;

  // Round 2: dump the first populated table's symbol objects (once).
  if (not DiagSymDumped) and DiagReadable(ATable, $10) and (PInteger(PByte(ATable) + 8)^ > 0) then
  begin
    DiagSymDumped := True;
    try
      DiagDumpTable(ATable);
    except
      DiagLog('  (exception during table walk)');
    end;
  end;
end;

function DiagFindCtorIatSlot(CompleteP, RealCtor: Pointer): PPointer;
var
  p, limit, t: PByte;
  slot: PPointer;
begin
  Result := nil;
  p := PByte(CompleteP);
  limit := p + $1200;
  while NativeUInt(p) < NativeUInt(limit) do
  begin
    if p^ = $E8 then
    begin
      try
        t := PByte(GetCallTargetAddress(p));   // E8 direct target = import stub
        if (t <> nil) and (t[0] = $FF) and (t[1] = $25) then
        begin
          slot := PPointer(t + 6 + PInteger(t + 2)^);   // FF25 -> *[rip+disp32] = IAT slot
          if slot^ = RealCtor then
          begin
            Result := slot;
            Exit;
          end;
        end;
      except
        // mis-aligned E8 operand pointing at unmapped memory - ignore
      end;
    end;
    Inc(p);
  end;
end;

procedure InstallAlphaSortDiag(Value: Boolean);
var
  hCore, hDsgn: THandle;
  RealCtor, CompleteP: Pointer;
  OldProt: DWORD;
begin
  if Value then
  begin
    if DiagCtorIatSlot <> nil then Exit;   // already installed

    hCore := GetModuleHandle(delphicoreide_bpl);
    hDsgn := GetModuleHandle(designide_bpl);
    if (hCore = 0) or (hDsgn = 0) then
    begin
      DiagLog('install: BPL not loaded (core=' + IntToStr(hCore) + ' dsgn=' + IntToStr(hDsgn) + ')');
      Exit;
    end;

    RealCtor := GetProcAddress(hDsgn, sDsgnTableIteratorCtor);
    if RealCtor = nil then
    begin
      DiagLog('install: ctor symbol not found in designide');
      Exit;
    end;

    CompleteP := GetActualAddr(@TPascalClassCompleter_Complete);
    if CompleteP = nil then
    begin
      DiagLog('install: Complete not resolved');
      Exit;
    end;
    DiagCompleteLo := NativeUInt(CompleteP);
    DiagCompleteHi := DiagCompleteLo + $1200;

    DiagCtorIatSlot := DiagFindCtorIatSlot(CompleteP, RealCtor);
    if DiagCtorIatSlot = nil then
    begin
      DiagLog('install: ctor IAT slot not found in Complete');
      Exit;
    end;

    DiagOrgCtor := RealCtor;
    DiagLogged := 0;
    DiagSymDumped := False;
    if VirtualProtect(DiagCtorIatSlot, SizeOf(Pointer), PAGE_READWRITE, OldProt) then
    begin
      DiagCtorIatSlot^ := @DiagIteratorCtor;
      VirtualProtect(DiagCtorIatSlot, SizeOf(Pointer), OldProt, OldProt);
      DiagLog(Format('install: hook active, IAT slot=%p, realCtor=%p, Complete=%p',
        [DiagCtorIatSlot, RealCtor, CompleteP]));
    end
    else
    begin
      DiagLog('install: VirtualProtect failed');
      DiagCtorIatSlot := nil;
    end;
  end
  else
  begin
    if DiagCtorIatSlot <> nil then
    begin
      if VirtualProtect(DiagCtorIatSlot, SizeOf(Pointer), PAGE_READWRITE, OldProt) then
      begin
        DiagCtorIatSlot^ := DiagOrgCtor;
        VirtualProtect(DiagCtorIatSlot, SizeOf(Pointer), OldProt, OldProt);
        DiagLog('uninstall: IAT slot restored');
      end;
      DiagCtorIatSlot := nil;
    end;
  end;
end;
{$ENDIF CPUX64}

procedure InstallDisableAlphaSortClassCompletion(Value: Boolean);
{$IFNDEF CPUX64}
const
  CompleteSetSortedBytes: array[0..18] of SmallInt = (
    $B2, $01,             // mov dl,$01                                    //  0
    $8B, $45, $F0,        // mov eax,[ebp-$10]                             //  2  == SortedThingList (used in CompleteMethodSymbolTableIteratorBytes)
    $E8, -1, -1, -1, -1,  // call TSortedThingList.SetSorted  ; $21ce165c  //  5
    $8B, $45, $F0,        // mov eax,[ebp-$10]                             // 10
    {$IF CompilerVersion >= 25.0} // XE4+
    $8B, $78, $08,        // mov edi,[eax+$08]                             // 13
    $4F,                  // dec edi                                       // 16
    $85, $FF              // test edi,edi                                  // 17
    {$ELSE}
    $8B, $70, $08,        // mov esi,[eax+$08]                             // 13
    $4E,                  // dec esi                                       // 16
    $85, $F6              // test esi,esi                                  // 17
    {$IFEND}
  );
  CallOffsetSetSorted = 5;

  CompleteMethodSymbolTableIteratorBytes: array[0..71] of SmallInt = (
    $8B, $45, $F8,                      // mov eax,[ebp-$08]                           //  0
    $8B, $88, -1, -1, $00, $00,         // mov ecx,[eax+$0000012c]                     //  3
    $B2, $01,                           // mov dl,$01                                  //  9
    $A1, -1, -1, -1, -1,                // mov eax,[$21df1e68]                         // 11
    $E8, -1, -1, -1, -1,                // call TTableIterator.Create  ; $21c646c4     // 16 // => call MethodSymbolTableIteratorFactory
    {$IF CompilerVersion = 21.0} // 2010 what did they do?
    $89, $45, $C0,                      // mov [ebp-$40],eax                           // 21
    {$ELSE}
    $89, $45, $C4,                      // mov [ebp-$3c],eax                           // 21
    {$IFEND}
    $33, $C0,                           // xor eax,eax                                 // 24
    $55,                                // push ebp                                    // 26
    $68, -1, -1, -1, -1,                // push $21ce114d                              // 27
    $64, $FF, $30,                      // push dword ptr fs:[eax]                     // 32
    $64, $89, $20,                      // mov fs:[eax],esp                            // 35
    {$IF CompilerVersion = 21.0} // 2010 what did they do?
    $8B, $45, $C0,                      // mov eax,[ebp-$40]                           // 38
    {$ELSE}
    $8B, $45, $C4,                      // mov eax,[ebp-$3c]                           // 38
    {$IFEND}
    $8B, -1, $10,                       // mov edi,[eax+$10]                           // 41
    -1,                                 // dec edi                                     // 44
    $85, -1,                            // test edi,edi                                // 45
    $0F, $8C, -1, -1, $00, $00,         // jl $21ce1137                                // 47
    -1,                                 // inc edi                                     // 53
    {$IF CompilerVersion = 21.0} // 2010 what did they do?
    $C7, $45, $CC, $00, $00, $00, $00,  // mov [ebp-$34],$00000000                     // 54
    $8B, $55, $CC,                      // mov edx,[ebp-$30]                           // 61
    $8B, $45, $C0,                      // mov eax,[ebp-$40]                           // 64
    {$ELSE}
    $C7, $45, $D0, $00, $00, $00, $00,  // mov [ebp-$30],$00000000                     // 54
    $8B, $55, $D0,                      // mov edx,[ebp-$34]                           // 61
    $8B, $45, $C4,                      // mov eax,[ebp-$3c]                           // 64
    {$IFEND}
    $E8, -1, -1, -1, -1                 // call TTableIterator.GetSymbol  ; $21c646cc  // 67  => replace with out GetSymbol method
  );
  CallOffsetTabCtor = 16;
  CallOffsetGetSymbol = 67;

begin
  if Value then
  begin
    if CallAddrTSortedThingList_SetSortedP = nil then
    begin
      CompleteMethodSymbolTableIteratorP := FindMethodPtr(GetActualAddr(@TPascalClassCompleter_Complete), CompleteMethodSymbolTableIteratorBytes, $10000);
      CallAddrTSortedThingList_SetSortedP := FindMethodPtr(CompleteMethodSymbolTableIteratorP, CompleteSetSortedBytes, $1000);

      // Code-Search: Breakpoint in TClassSymbol_MethodAddPos_AlphSort, start, add method to class decl., press Ctrl+Shift+C, debug through function returns until you are in method "Complete"
      if (CallAddrTSortedThingList_SetSortedP = nil) and (DebugHook <> 0) then
        MessageBox(0, 'InstallDisableAlphaSortClassCompletion byte sequences not found', 'DDevExtensions', MB_OK or MB_ICONWARNING);

      if (CompleteMethodSymbolTableIteratorP <> nil) and (CallAddrTSortedThingList_SetSortedP <> nil) then
      begin
        OrgTTableIterator_Ctor := GetCallTargetAddress(@CompleteMethodSymbolTableIteratorP[CallOffsetTabCtor]);
        OrgTTableIterator_GetSymbol := GetCallTargetAddress(@CompleteMethodSymbolTableIteratorP[CallOffsetGetSymbol]);
        OrgTSortedThingList_SetSorted := GetCallTargetAddress(@CallAddrTSortedThingList_SetSortedP[CallOffsetSetSorted]);
      end
      else
      begin
        // No "disabled sorting" of the generated methods, but the insert position patch can still work
        CompleteMethodSymbolTableIteratorP := nil;
        CallAddrTSortedThingList_SetSortedP := nil;
      end;
    end;

    if (CompleteMethodSymbolTableIteratorP <> nil) and (CallAddrTSortedThingList_SetSortedP <> nil) then
    begin
      ReplaceRelCallOffset(@CompleteMethodSymbolTableIteratorP[CallOffsetTabCtor], @MethodSymbolTableIteratorFactory);
      ReplaceRelCallOffset(@CompleteMethodSymbolTableIteratorP[CallOffsetGetSymbol], @TTableIterator.GetSymbol);
      ReplaceRelCallOffset(@CallAddrTSortedThingList_SetSortedP[CallOffsetSetSorted], @TSortedThingList_SetSorted);
    end;

    if Assigned(OrgTClassSymbol_MethodAddPos) then
      RedirectOrg(@TClassSymbol_MethodAddPos, @TClassSymbol_MethodAddPos_AlphSort)
    else
      @OrgTClassSymbol_MethodAddPos := RedirectOrgCall(@TClassSymbol_MethodAddPos, @TClassSymbol_MethodAddPos_AlphSort);
  end
  else
  begin
    RestoreOrgCall(@TClassSymbol_MethodAddPos, @OrgTClassSymbol_MethodAddPos);
    if (CompleteMethodSymbolTableIteratorP <> nil) and (OrgTTableIterator_Ctor <> nil) then
      ReplaceRelCallOffset(@CompleteMethodSymbolTableIteratorP[CallOffsetTabCtor], OrgTTableIterator_Ctor);
    if (CompleteMethodSymbolTableIteratorP <> nil) and (OrgTTableIterator_GetSymbol <> nil) then
      ReplaceRelCallOffset(@CompleteMethodSymbolTableIteratorP[CallOffsetGetSymbol], OrgTTableIterator_GetSymbol);
    if (CallAddrTSortedThingList_SetSortedP <> nil) and (OrgTSortedThingList_SetSorted <> nil) then
      ReplaceRelCallOffset(@CallAddrTSortedThingList_SetSortedP[CallOffsetSetSorted], OrgTSortedThingList_SetSorted);
  end;
end;
{$ELSE}
begin
  // Win64 (Delphi 13): diagnostic-first step 1 — see the CPUX64 block above.
  InstallAlphaSortDiag(Value);
end;
{$ENDIF ~CPUX64}

{$IFEND}

end.
