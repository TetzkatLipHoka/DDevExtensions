{******************************************************************************}
{*                                                                            *}
{* DDevExtensions                                                             *}
{*                                                                            *}
{* Normalize line endings to CRLF when a file is opened                       *}
{*                                                                            *}
{******************************************************************************}

unit NormalizeLineEndings;

{
  Optional feature: when a Delphi source file is opened in the editor, rewrite
  any lone LF or lone CR line endings to CRLF. LF-only files (e.g. produced by
  cross-platform tools) confuse parts of the IDE - notably the package-source
  updater, which mangles keywords when adding/removing units in an LF-only .dpk.

  The change goes into the editor buffer as a single undoable edit (the file
  shows as modified and the user controls when it is saved), and only when a
  file actually needs it - already-CRLF files are left untouched, so they do
  NOT show up as modified.

  The rewrite is DEFERRED off the ofnFileOpened notification via a short timer:
  modifying the buffer from inside the open callback (while the IDE is still
  loading it) is fragile, so we queue the file name and process it once the IDE
  is idle and the buffer is fully populated.
}

interface

procedure InstallNormalizeLineEndings(Value: Boolean);

implementation

uses
  Windows, SysUtils, Classes, ExtCtrls, ToolsAPI, ToolsAPIHelpers;

type
  TLineEndingNotifier = class(TNotifierObject, IOTAIDENotifier)
  public
    procedure FileNotification(NotifyCode: TOTAFileNotification;
      const FileName: string; var Cancel: Boolean);
    procedure BeforeCompile(const Project: IOTAProject; var Cancel: Boolean);
    procedure AfterCompile(Succeeded: Boolean);
  end;

  { holds the TTimer.OnTimer method (a plain procedure can't be assigned to it) }
  TTimerHandler = class
    procedure DoTimer(Sender: TObject);
  end;

var
  GNotifierIndex: Integer = -1;
  GPending: TStringList;
  GTimer: TTimer;
  GTimerHandler: TTimerHandler;
  GProcessing: Boolean;

{ Only touch Delphi source files - project/desktop/binary files are left alone. }
function IsNormalizableExt(const FileName: string): Boolean;
var
  e: string;
begin
  e := LowerCase(ExtractFileExt(FileName));
  Result := (e = '.pas') or (e = '.dpr') or (e = '.dpk') or
            (e = '.inc') or (e = '.pp');
end;

{ Convert every lone LF and lone CR to CRLF; Changed is True only if the input
  was not already fully CRLF (so already-normalized files are not rewritten).
  UTF8-safe: CR ($0D) and LF ($0A) never occur inside a UTF-8 multibyte code. }
function NormalizeToCRLF(const S: UTF8String; out Changed: Boolean): UTF8String;
var
  n, i, j: Integer;
  c: AnsiChar;
begin
  Changed := False;
  n := Length(S);
  SetLength(Result, n * 2); // worst case: every byte a lone LF/CR -> doubles
  j := 0;
  i := 1;
  while i <= n do
  begin
    c := S[i];
    if c = #10 then                 // lone LF -> CRLF
    begin
      Inc(j); Result[j] := #13;
      Inc(j); Result[j] := #10;
      Changed := True;
      Inc(i);
    end
    else if c = #13 then            // CR, possibly the CR of a CRLF
    begin
      Inc(j); Result[j] := #13;
      Inc(j); Result[j] := #10;
      if (i < n) and (S[i + 1] = #10) then
        Inc(i, 2)                   // proper CRLF - not a change
      else
      begin
        Changed := True;            // lone CR -> CRLF
        Inc(i);
      end;
    end
    else
    begin
      Inc(j); Result[j] := c;
      Inc(i);
    end;
  end;
  SetLength(Result, j);
end;

procedure NormalizeSourceEditor(const Editor: IOTASourceEditor);
var
  Src, Norm: UTF8String;
  Changed: Boolean;
  Writer: IOTAEditWriter;
begin
  Src := GetEditorSource(Editor);
  if Src = '' then
    Exit;
  Norm := NormalizeToCRLF(Src, Changed);
  if not Changed then
    Exit;
  Writer := Editor.CreateUndoableWriter;
  Writer.DeleteTo(MaxInt);
  Writer.Insert(PAnsiChar(Norm));
end;

procedure NormalizeFile(const FileName: string);
var
  ModServices: IOTAModuleServices;
  Module: IOTAModule;
  i: Integer;
  Src: IOTASourceEditor;
begin
  if not IsNormalizableExt(FileName) then
    Exit;
  ModServices := BorlandIDEServices as IOTAModuleServices;
  Module := ModServices.FindModule(FileName);
  if Module = nil then
    Exit; // closed again meanwhile
  for i := 0 to Module.GetModuleFileCount - 1 do
    if Supports(Module.GetModuleFileEditor(i), IOTASourceEditor, Src) and
       SameText(Src.FileName, FileName) then
      NormalizeSourceEditor(Src);
end;

procedure TTimerHandler.DoTimer(Sender: TObject);
var
  Names: TStringList;
  i: Integer;
begin
  GTimer.Enabled := False;
  if GProcessing or (GPending = nil) then
    Exit;
  GProcessing := True;
  try
    Names := TStringList.Create;
    try
      Names.Assign(GPending);
      GPending.Clear;
      for i := 0 to Names.Count - 1 do
      try
        NormalizeFile(Names[i]);
      except
        // one bad file must never break the others or the IDE
      end;
    finally
      Names.Free;
    end;
  finally
    GProcessing := False;
  end;
end;

{ TLineEndingNotifier }

procedure TLineEndingNotifier.FileNotification(NotifyCode: TOTAFileNotification;
  const FileName: string; var Cancel: Boolean);
begin
  if (NotifyCode <> ofnFileOpened) or (GPending = nil) then
    Exit;
  if not IsNormalizableExt(FileName) then
    Exit;
  if GPending.IndexOf(FileName) < 0 then
    GPending.Add(FileName);
  if GTimer <> nil then
  begin
    GTimer.Enabled := False; // re-arm so bursts of opens coalesce
    GTimer.Enabled := True;
  end;
end;

procedure TLineEndingNotifier.BeforeCompile(const Project: IOTAProject; var Cancel: Boolean);
begin
end;

procedure TLineEndingNotifier.AfterCompile(Succeeded: Boolean);
begin
end;

procedure InstallNormalizeLineEndings(Value: Boolean);
var
  Services: IOTAServices;
begin
  if Value then
  begin
    if GNotifierIndex >= 0 then
      Exit; // already installed
    GPending := TStringList.Create;
    GTimerHandler := TTimerHandler.Create;
    GTimer := TTimer.Create(nil);
    GTimer.Enabled := False;
    GTimer.Interval := 150;
    GTimer.OnTimer := GTimerHandler.DoTimer;
    Services := BorlandIDEServices as IOTAServices;
    GNotifierIndex := Services.AddNotifier(TLineEndingNotifier.Create);
  end
  else
  begin
    if GNotifierIndex >= 0 then
    begin
      (BorlandIDEServices as IOTAServices).RemoveNotifier(GNotifierIndex);
      GNotifierIndex := -1;
    end;
    FreeAndNil(GTimer);
    FreeAndNil(GTimerHandler);
    FreeAndNil(GPending);
  end;
end;

initialization

finalization
  InstallNormalizeLineEndings(False);

end.
