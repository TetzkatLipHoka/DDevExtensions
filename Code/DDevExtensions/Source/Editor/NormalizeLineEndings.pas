{******************************************************************************}
{*                                                                            *}
{* DDevExtensions                                                             *}
{*                                                                            *}
{* Normalize line endings to CRLF when a file is opened                       *}
{*                                                                            *}
{******************************************************************************}

unit NormalizeLineEndings;

{
  Optional feature: when a Delphi source file is opened, rewrite any lone LF or
  lone CR line ending to CRLF. LF-only files (e.g. produced by cross-platform
  tools) confuse parts of the IDE - notably the package-source updater, which
  mangles keywords when adding/removing units in an LF-only .dpk.

  Implementation: normalize the file ON DISK on ofnFileOpening, i.e. BEFORE the
  IDE reads it. That is deliberately NOT done through the editor buffer:
    * The editor has no public API to set a buffer's end-of-line style
      (TOTAEndLine is read-only per-line info). When an all-LF file is loaded,
      the editor remembers "LF" and re-emits the file's FINAL line ending as a
      lone LF on save even after the buffer content was rewritten to CRLF - so a
      buffer rewrite leaves a stray trailing 0x0A (fixed only on the next load).
    * Normalizing the bytes on disk before the load sidesteps all of that: the
      IDE loads a clean CRLF file, detects CRLF, no stray trailing LF, and the
      file is not left marked-as-modified.

  Only files that actually need it are rewritten (already-CRLF files are left
  untouched, so clean files are never rewritten), read-only files are skipped,
  and every step is guarded so a failure can never break file opening.
  Byte-level CR/LF handling is UTF-8 safe (CR/LF never occur inside a multibyte
  code point), and a BOM or any other bytes are preserved verbatim.
}

interface

procedure InstallNormalizeLineEndings(Value: Boolean);

implementation

uses
  Windows, SysUtils, Classes, ToolsAPI;

type
  TLineEndingNotifier = class(TNotifierObject, IOTAIDENotifier)
  public
    procedure FileNotification(NotifyCode: TOTAFileNotification;
      const FileName: string; var Cancel: Boolean);
    procedure BeforeCompile(const Project: IOTAProject; var Cancel: Boolean);
    procedure AfterCompile(Succeeded: Boolean);
  end;

var
  GNotifierIndex: Integer = -1;

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
  was not already fully CRLF (so already-normalized files are not rewritten). }
function NormalizeToCRLF(const S: AnsiString; out Changed: Boolean): AnsiString;
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

function ReadFileBytes(const FileName: string): AnsiString;
var
  Stream: TFileStream;
begin
  Result := '';
  Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
  try
    if Stream.Size > 0 then
    begin
      SetLength(Result, Stream.Size);
      Stream.ReadBuffer(Result[1], Stream.Size);
    end;
  finally
    Stream.Free;
  end;
end;

procedure WriteFileBytes(const FileName: string; const Data: AnsiString);
var
  Stream: TFileStream;
begin
  Stream := TFileStream.Create(FileName, fmCreate);
  try
    if Length(Data) > 0 then
      Stream.WriteBuffer(Data[1], Length(Data));
  finally
    Stream.Free;
  end;
end;

procedure NormalizeDiskFile(const FileName: string);
var
  Attr: Integer;
  Data, Norm: AnsiString;
  Changed: Boolean;
begin
  if not IsNormalizableExt(FileName) then
    Exit;
  if not FileExists(FileName) then
    Exit;                             // new/virtual file - nothing on disk yet
  Attr := FileGetAttr(FileName);
  if (Attr < 0) or ((Attr and faReadOnly) <> 0) then
    Exit;                             // read-only: don't touch (e.g. VCS-locked)
  Data := ReadFileBytes(FileName);
  if Data = '' then
    Exit;
  Norm := NormalizeToCRLF(Data, Changed);
  if Changed then
    WriteFileBytes(FileName, Norm);   // IDE reads the clean CRLF file right after
end;

{ TLineEndingNotifier }

procedure TLineEndingNotifier.FileNotification(NotifyCode: TOTAFileNotification;
  const FileName: string; var Cancel: Boolean);
begin
  if NotifyCode <> ofnFileOpening then
    Exit;
  try
    NormalizeDiskFile(FileName);
  except
    // normalizing must never break opening the file
  end;
end;

procedure TLineEndingNotifier.BeforeCompile(const Project: IOTAProject; var Cancel: Boolean);
begin
end;

procedure TLineEndingNotifier.AfterCompile(Succeeded: Boolean);
begin
end;

procedure InstallNormalizeLineEndings(Value: Boolean);
begin
  if Value then
  begin
    if GNotifierIndex >= 0 then
      Exit; // already installed
    GNotifierIndex := (BorlandIDEServices as IOTAServices).AddNotifier(TLineEndingNotifier.Create);
  end
  else
  begin
    if GNotifierIndex >= 0 then
    begin
      (BorlandIDEServices as IOTAServices).RemoveNotifier(GNotifierIndex);
      GNotifierIndex := -1;
    end;
  end;
end;

initialization

finalization
  InstallNormalizeLineEndings(False);

end.
