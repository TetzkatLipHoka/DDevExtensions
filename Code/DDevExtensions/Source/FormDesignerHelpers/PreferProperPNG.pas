{******************************************************************************}
{*                                                                            *}
{* DDevExtensions                                                             *}
{*                                                                            *}
{* Prefer the proper TPNGGraphic over AlphaControls' acPNG (order arbiter)    *}
{*                                                                            *}
{******************************************************************************}

unit PreferProperPNG;

{$I ..\DelphiExtension.inc}

{
  AlphaControls' acPNG unit and the proper PNG implementation both register a
  graphic class NAMED 'TPNGGraphic' in the VCL's global TFileFormatsList. A
  DFM stores only that class-name string; TPicture.ReadData resolves it via
  FileFormats.FindClassName, which iterates "for I := Count-1 downto 0" - so
  the LAST registered class wins (verified in D7 and D13 Graphics.pas alike).
  Package load order is not guaranteed, so sometimes acPNG wins and pictures
  stay acPNG's fake PNG (a BMP stored under the PNG class name, not portable).

  This feature arbitrates the registration ORDER instead of fighting the
  registration itself: it locates the global list via the FileFormatsListHack
  disassembler hack, identifies "our" proper TPNGGraphic - the one from the
  pngimage unit (pre-2009: the user's pngimage package) or DDev's own
  FixAlphaControlsPNG class (D2009+, when that fix is compiled in) - and moves
  that entry to the END of the list so it wins the last-wins lookup.
  Non-destructive (acPNG stays registered, AlphaControls' runtime behavior is
  untouched) and idempotent, so it can run any number of times.

  It runs when the feature is activated and again on every
  ofnPackageInstalled/ofnPackageUninstalled notification, which catches an
  AlphaControls package that is (re)loaded after DDevExtensions.

  Diagnostics: whenever a run sees a list state it has not logged yet, it
  appends a dump of the whole file-format list (index, class, unit, extension)
  plus the action taken to %APPDATA%\DDevExtensions\PNGArbiter.log - the dump
  of the pre-move state is written BEFORE the list is mutated.
}

interface

procedure SetPreferProperPNGActive(Active: Boolean);

implementation

uses
  Windows, SysUtils, Classes, TypInfo, Graphics, ToolsAPI,
  FileFormatsListHack
  {$IF Defined(COMPILER12_UP) and Defined(INCLUDE_ACPNGFIX)}
  , FixAlphaControlsPNG
  {$IFEND};

const
  SPNGGraphicClassName = 'TPNGGraphic';
  // The proper PNG unit. Pre-2009 this is the user's pngimage package (kept in
  // sync with the retail pngimage and never renamed); 2009+ a third-party
  // package built from pngimage would match, too.
  SProperPngUnitName = 'pngimage';

type
  TPngArbiterNotifier = class(TNotifierObject, IOTAIDENotifier)
  public
    procedure FileNotification(NotifyCode: TOTAFileNotification;
      const FileName: string; var Cancel: Boolean);
    procedure BeforeCompile(const Project: IOTAProject; var Cancel: Boolean);
    procedure AfterCompile(Succeeded: Boolean);
  end;

var
  GNotifierIndex: Integer = -1;
  GLastLoggedState: string; // last logged list signature - suppresses log spam

{ Classic RTTI (works from D7 on): the unit a class was declared in. }
function ClassUnitName(AClass: TClass): string;
begin
  Result := '';
  if (AClass <> nil) and (AClass.ClassInfo <> nil) then
    Result := string(GetTypeData(AClass.ClassInfo)^.UnitName);
end;

{ Is this the TPNGGraphic that should win? The arbiter does not need to know
  acPNG - it only promotes "ours"; every other same-named class simply loses. }
function IsProperPNGGraphic(AClass: TGraphicClass): Boolean;
begin
  Result := SameText(ClassUnitName(AClass), SProperPngUnitName);
  {$IF Defined(COMPILER12_UP) and Defined(INCLUDE_ACPNGFIX)}
  Result := Result or (AClass = FixAlphaControlsPNG.TPNGGraphic);
  {$IFEND}
end;

procedure AppendLog(const Text: string);
var
  Dir, Fn: string;
  F: TextFile;
begin
  try
    Dir := GetEnvironmentVariable('APPDATA') + '\DDevExtensions';
    ForceDirectories(Dir);
    Fn := Dir + '\PNGArbiter.log';
    AssignFile(F, Fn);
    if FileExists(Fn) then
      Append(F)
    else
      Rewrite(F);
    try
      Write(F, Text);
    finally
      CloseFile(F);
    end;
  except
    // diagnostics must never break the IDE
  end;
end;

{ Signature of the current list ordering; also used to decide whether the
  state is worth logging again. }
function ListSignature(List: TFileFormatsListHack): string;
var
  i: Integer;
  GC: TGraphicClass;
begin
  Result := '';
  for i := 0 to List.Count - 1 do
  begin
    GC := List[i]^.GraphicClass;
    Result := Result + IntToStr(i) + ':' + GC.ClassName + ':' +
      ClassUnitName(GC) + '|';
  end;
end;

procedure Arbitrate(const Trigger: string);
var
  List: TFileFormatsListHack;
  Dump: TStringList;
  State, Action, UnitName: string;
  i, OurIndex, LastOtherIndex: Integer;
  GC: TGraphicClass;
begin
  try
    if not Assigned(GetFileFormats) then
    begin
      if GLastLoggedState <> '<no-hack>' then
      begin
        GLastLoggedState := '<no-hack>';
        AppendLog('[' + DateTimeToStr(Now) + '] ' + Trigger + ': ' +
          'GetFileFormats hack failed (unexpected TPicture.RegisterFileFormat' +
          ' code layout) - PNG arbiter inactive' + sLineBreak);
      end;
      Exit;
    end;

    List := GetFileFormats();
    if List = nil then
      Exit;

    // find "our" proper TPNGGraphic (highest index) and the highest-indexed
    // OTHER class of the same name (the one that would currently beat us)
    OurIndex := -1;
    LastOtherIndex := -1;
    for i := 0 to List.Count - 1 do
    begin
      GC := List[i]^.GraphicClass;
      if GC.ClassName = SPNGGraphicClassName then
      begin
        if IsProperPNGGraphic(GC) then
          OurIndex := i
        else
          LastOtherIndex := i;
      end;
    end;

    // log the pre-move state BEFORE mutating (once per distinct state)
    State := ListSignature(List);
    if State <> GLastLoggedState then
    begin
      Dump := TStringList.Create;
      try
        Dump.Add('================ PNG arbiter [' + DateTimeToStr(Now) +
          '] trigger: ' + Trigger + ' ================');
        Dump.Add('file-format list before (last entry wins, Count=' +
          IntToStr(List.Count) + '):');
        for i := 0 to List.Count - 1 do
        begin
          GC := List[i]^.GraphicClass;
          UnitName := ClassUnitName(GC);
          Dump.Add(Format('  [%2d] %-16s unit=%-24s ext=''%s''',
            [i, GC.ClassName, UnitName, List[i]^.Extension]));
        end;
        AppendLog(Dump.Text);
      finally
        Dump.Free;
      end;
    end;

    if (OurIndex >= 0) and (LastOtherIndex > OurIndex) then
    begin
      List.Move(OurIndex, List.Count - 1);
      Action := Format('moved proper TPNGGraphic [%d] -> [%d] so it wins ' +
        'over foreign TPNGGraphic [%d]',
        [OurIndex, List.Count - 1, LastOtherIndex]);
    end
    else if OurIndex < 0 then
    begin
      if LastOtherIndex >= 0 then
        Action := 'foreign TPNGGraphic at [' + IntToStr(LastOtherIndex) +
          '] but no proper one registered - nothing to promote'
      else
        Action := 'no TPNGGraphic entries - nothing to do';
    end
    else
      Action := 'proper TPNGGraphic at [' + IntToStr(OurIndex) +
        '] already wins - no change';

    if State <> GLastLoggedState then
      AppendLog('action: ' + Action + sLineBreak + sLineBreak);

    // remember the RESULTING state so an unchanged follow-up run stays silent
    GLastLoggedState := ListSignature(List);
  except
    // arbitrating must never break the IDE (e.g. if the disassembled
    // GetFileFormats address turns out to be bogus)
  end;
end;

{ TPngArbiterNotifier }

procedure TPngArbiterNotifier.FileNotification(NotifyCode: TOTAFileNotification;
  const FileName: string; var Cancel: Boolean);
begin
  case NotifyCode of
    ofnPackageInstalled:
      Arbitrate('package installed: ' + ExtractFileName(FileName));
    ofnPackageUninstalled:
      Arbitrate('package uninstalled: ' + ExtractFileName(FileName));
  end;
end;

procedure TPngArbiterNotifier.BeforeCompile(const Project: IOTAProject; var Cancel: Boolean);
begin
end;

procedure TPngArbiterNotifier.AfterCompile(Succeeded: Boolean);
begin
end;

procedure SetPreferProperPNGActive(Active: Boolean);
begin
  if Active then
  begin
    if GNotifierIndex >= 0 then
      Exit; // already installed
    GNotifierIndex := (BorlandIDEServices as IOTAServices).AddNotifier(TPngArbiterNotifier.Create);
    Arbitrate('feature activated');
  end
  else
  begin
    if GNotifierIndex >= 0 then
    begin
      (BorlandIDEServices as IOTAServices).RemoveNotifier(GNotifierIndex);
      GNotifierIndex := -1;
    end;
    // deliberately no "undo": the reorder is non-destructive and harmless
  end;
end;

initialization

finalization
  SetPreferProperPNGActive(False);

end.
