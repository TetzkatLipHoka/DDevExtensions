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
{$IFDEF ALPHASORT_X64_WIP}
// ---------------------------------------------------------------------------
//  Delphi 13 x64 implementation. The x86 path scans Complete for byte patterns
//  and ReplaceRelCallOffset-patches the iterator ctor / GetSymbol / SetSorted
//  calls. On x64 those calls are IMPORTED from designide370 (Symbols::
//  TTableIterator) via delphicoreide370 IAT stubs, and there is no separate
//  SetSorted call (folded into the ctor). All the object layouts this unit
//  relies on (TSymbolTable.FCount@+8/FSymbolList@+0x10, TBaseSymbol.Next@+8,
//  TMethodSymbol.FMethodSignature@+0x118, TMethodSignature.HeaderPos@+0x1C/
//  CodePos@+0x2C, TTableIterator.FCount@+0x18) were confirmed by a diagnostic
//  round against the live IDE and match exactly what the compiler generates
//  for these decls on x64 (see scratchpad alphasort_x64_offsets.md).
//
//  Wiring strategy: patch the ctor & GetSymbol IAT slots (full 64-bit pointer,
//  so no rel32 / near-trampoline concern) to gate functions that check whether
//  the caller's return address is inside TPascalClassCompleter.Complete:
//    - from Complete  -> our reordering factory / GetSymbol (declaration order)
//    - otherwise      -> delegate to the real designide ctor / GetSymbol
//  so the IDE-wide IAT patch is safe for every other caller. The MethodAddPos
//  redirect is a normal function-entry hook (RedirectOrgCall), as on x86.
// ---------------------------------------------------------------------------
const
  sDsgnTableIteratorCtor      = '_ZN7Symbols14TTableIteratorC3EPNS_12TSymbolTableE';
  sDsgnTableIteratorGetSymbol = '_ZN7Symbols14TTableIterator9GetSymbolEi';

type
  TIteratorCtorProc = function(AClass: Pointer; AllocFlag: NativeInt; ATable: Pointer): Pointer;
  TIteratorGetSymProc = function(Instance: Pointer; Index: Integer): Pointer;

var
  AlphaCtorIatSlot: PPointer;    // delphicoreide370 IAT slot for the ctor
  AlphaGetSymIatSlot: PPointer;  // delphicoreide370 IAT slot for GetSymbol
  AlphaOrgCtor: Pointer;         // real designide ctor
  AlphaOrgGetSym: Pointer;       // real designide GetSymbol
  AlphaCompleteLo, AlphaCompleteHi: NativeUInt;
  AlphaMethodAddPosHooked: Boolean;
  AlphaCtorN, AlphaGetN: Integer;   // DIAG: instrumentation counters

procedure AlphaLog(const S: string);
var
  F: TextFile;
  FileName: string;
begin
  try
    FileName := GetEnvironmentVariable('APPDATA') + '\DDevExtensions\AlphaSort.log';
    AssignFile(F, FileName);
    if FileExists(FileName) then Append(F) else Rewrite(F);
    try
      WriteLn(F, S);
    finally
      CloseFile(F);
    end;
  except
    // status logging must never break the IDE
  end;
end;

function AlphaShortName(Sym: Pointer): string;   // read FShortIdent (ShortString @ +0x10)
var
  b: PByte;
  n, i: Integer;
begin
  Result := '';
  if Sym = nil then Exit;
  try
    b := PByte(Sym) + $10;
    n := b^;
    if n > 63 then n := 63;
    for i := 1 to n do
      Result := Result + Char(b[i]);
  except
    Result := '?';
  end;
end;

// A ctor call from inside Complete gets our reordering iterator; every other
// caller in the IDE gets the untouched designide iterator.
function AlphaCtorGate(AClass: Pointer; AllocFlag: NativeInt; ATable: Pointer): Pointer;
var
  ra: NativeUInt;
  it: TTableIterator;
  i: Integer;
  s: string;
begin
  ra := NativeUInt(ReturnAddress);
  if (ra >= AlphaCompleteLo) and (ra < AlphaCompleteHi) then
  begin
    it := MethodSymbolTableIteratorFactory(TClass(AClass), Integer(AllocFlag), TSymbolTable(ATable));
    Result := it;
    Inc(AlphaCtorN);
    if AlphaCtorN <= 4 then
    try
      s := '';
      for i := 0 to it.Count - 1 do
        s := s + AlphaShortName(it.GetSymbol(i)) + ',';
      AlphaLog(Format('DIAG ctor#%d substituted ra=%p count=%d order=[%s]',
        [AlphaCtorN, Pointer(ra), it.Count, s]));
    except
      AlphaLog('DIAG ctor log exception');
    end;
  end
  else
    Result := TIteratorCtorProc(AlphaOrgCtor)(AClass, AllocFlag, ATable);
end;

function AlphaGetSymGate(Instance: Pointer; Index: Integer): Pointer;
var
  ra: NativeUInt;
begin
  ra := NativeUInt(ReturnAddress);
  if (ra >= AlphaCompleteLo) and (ra < AlphaCompleteHi) then
  begin
    Result := TTableIterator(Instance).GetSymbol(Index);
    Inc(AlphaGetN);
    if AlphaGetN <= 40 then
      AlphaLog(Format('DIAG getsym ra=%p idx=%d -> %s', [Pointer(ra), Index, AlphaShortName(Result)]));
  end
  else
    Result := TIteratorGetSymProc(AlphaOrgGetSym)(Instance, Index);
end;

function AlphaReadable(P: Pointer; Len: NativeUInt): Boolean;
var
  mbi: TMemoryBasicInformation;
begin
  Result := False;
  if (P = nil) or (NativeUInt(P) < $10000) then Exit;
  if VirtualQuery(P, mbi, SizeOf(mbi)) = 0 then Exit;
  if mbi.State <> MEM_COMMIT then Exit;
  if (mbi.Protect and (PAGE_NOACCESS or PAGE_GUARD)) <> 0 then Exit;
  Result := NativeUInt(P) + Len <= NativeUInt(mbi.BaseAddress) + NativeUInt(mbi.RegionSize);
end;

// Locate the delphicoreide IAT slot that Complete uses to reach a designide
// export, by scanning Complete for the E8 call whose import stub reads a slot
// currently holding RealFn.
function AlphaFindIatSlot(CompleteP, RealFn: Pointer): PPointer;
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
        t := PByte(GetCallTargetAddress(p));       // E8 direct target = import stub
        if (t <> nil) and (t[0] = $FF) and (t[1] = $25) then
        begin
          slot := PPointer(t + 6 + PInteger(t + 2)^); // FF25 -> *[rip+disp32] = IAT slot
          if AlphaReadable(slot, SizeOf(Pointer)) and (slot^ = RealFn) then
          begin
            Result := slot;
            Exit;
          end;
        end;
      except
        // mis-aligned E8 operand - ignore
      end;
    end;
    Inc(p);
  end;
end;

function AlphaPatchSlot(Slot: PPointer; NewValue: Pointer): Boolean;
var
  OldProt: DWORD;
begin
  Result := False;
  if (Slot = nil) or not AlphaReadable(Slot, SizeOf(Pointer)) then Exit;
  if VirtualProtect(Slot, SizeOf(Pointer), PAGE_READWRITE, OldProt) then
  begin
    Slot^ := NewValue;
    VirtualProtect(Slot, SizeOf(Pointer), OldProt, OldProt);
    Result := True;
  end;
end;

procedure InstallAlphaSortX64(Value: Boolean);
var
  hCore, hDsgn: THandle;
  CompleteP: Pointer;
begin
  if Value then
  begin
    if AlphaCtorIatSlot <> nil then Exit;   // already installed

    hCore := GetModuleHandle(delphicoreide_bpl);
    hDsgn := GetModuleHandle(designide_bpl);
    if (hCore = 0) or (hDsgn = 0) then
    begin
      AlphaLog(Format('install: BPL not loaded (core=%d dsgn=%d)', [hCore, hDsgn]));
      Exit;
    end;

    AlphaOrgCtor := GetProcAddress(hDsgn, sDsgnTableIteratorCtor);
    AlphaOrgGetSym := GetProcAddress(hDsgn, sDsgnTableIteratorGetSymbol);
    if (AlphaOrgCtor = nil) or (AlphaOrgGetSym = nil) then
    begin
      AlphaLog('install: designide ctor/GetSymbol symbol not found');
      Exit;
    end;

    CompleteP := GetActualAddr(@TPascalClassCompleter_Complete);
    if CompleteP = nil then
    begin
      AlphaLog('install: Complete not resolved');
      Exit;
    end;
    AlphaCompleteLo := NativeUInt(CompleteP);
    AlphaCompleteHi := AlphaCompleteLo + $1200;
    AlphaCtorN := 0;   // DIAG
    AlphaGetN := 0;    // DIAG

    AlphaCtorIatSlot := AlphaFindIatSlot(CompleteP, AlphaOrgCtor);
    AlphaGetSymIatSlot := AlphaFindIatSlot(CompleteP, AlphaOrgGetSym);
    if (AlphaCtorIatSlot = nil) or (AlphaGetSymIatSlot = nil) then
    begin
      AlphaLog(Format('install: IAT slot not found (ctor=%p getsym=%p)',
        [AlphaCtorIatSlot, AlphaGetSymIatSlot]));
      AlphaCtorIatSlot := nil;
      AlphaGetSymIatSlot := nil;
      Exit;
    end;

    if not AlphaPatchSlot(AlphaCtorIatSlot, @AlphaCtorGate) then
    begin
      AlphaLog('install: ctor slot patch failed');
      AlphaCtorIatSlot := nil;
      AlphaGetSymIatSlot := nil;
      Exit;
    end;
    if not AlphaPatchSlot(AlphaGetSymIatSlot, @AlphaGetSymGate) then
    begin
      AlphaPatchSlot(AlphaCtorIatSlot, AlphaOrgCtor); // roll back ctor patch
      AlphaLog('install: getsym slot patch failed');
      AlphaCtorIatSlot := nil;
      AlphaGetSymIatSlot := nil;
      Exit;
    end;

    // Insertion-position redirect (same as x86): make MethodAddPos behave as if
    // the new method name were empty. RedirectOrgCall handles the x64 trampoline.
    if not AlphaMethodAddPosHooked then
    begin
      if Assigned(OrgTClassSymbol_MethodAddPos) then
        RedirectOrg(@TClassSymbol_MethodAddPos, @TClassSymbol_MethodAddPos_AlphSort)
      else
        @OrgTClassSymbol_MethodAddPos := RedirectOrgCall(@TClassSymbol_MethodAddPos, @TClassSymbol_MethodAddPos_AlphSort);
      AlphaMethodAddPosHooked := True;
    end;

    AlphaLog(Format('install: active (ctorSlot=%p getsymSlot=%p Complete=%p)',
      [AlphaCtorIatSlot, AlphaGetSymIatSlot, CompleteP]));
  end
  else
  begin
    if AlphaCtorIatSlot <> nil then
    begin
      AlphaPatchSlot(AlphaCtorIatSlot, AlphaOrgCtor);
      AlphaCtorIatSlot := nil;
    end;
    if AlphaGetSymIatSlot <> nil then
    begin
      AlphaPatchSlot(AlphaGetSymIatSlot, AlphaOrgGetSym);
      AlphaGetSymIatSlot := nil;
    end;
    if AlphaMethodAddPosHooked then
    begin
      RestoreOrgCall(@TClassSymbol_MethodAddPos, @OrgTClassSymbol_MethodAddPos);
      AlphaMethodAddPosHooked := False;
    end;
    AlphaLog('uninstall: restored');
  end;
end;
{$ENDIF ALPHASORT_X64_WIP}
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
  {$IFDEF ALPHASORT_X64_WIP}
  // Win64 (Delphi 13): IAT-gated reorder + MethodAddPos redirect (see CPUX64 block above).
  InstallAlphaSortX64(Value);
  {$ELSE}
  // Win64: DISABLED pending deeper RE. The reorder iterator was confirmed working (it feeds
  // TPascalClassCompleter.Complete the methods in declaration order), but on D13 that is NOT the
  // lever that orders the generated implementation stubs - the completer re-sorts its "to add"
  // list alphabetically afterwards (the x86 feature also no-ops a TSortedThingList.SetSorted call;
  // the x64 equivalent has not been located yet), so output stayed alphabetical. The hooks also
  // destabilised the editor (Home on a blank line raised an exception - likely the IDE-wide
  // MethodAddPos redirect and/or the ReturnAddress window overshooting Complete into GetClasses).
  // Full implementation + confirmed x64 offsets are preserved under {$DEFINE ALPHASORT_X64_WIP}
  // above and in git (65463f8); notes in scratchpad alphasort_x64_offsets.md.
  {$ENDIF}
end;
{$ENDIF ~CPUX64}

{$IFEND}

end.
