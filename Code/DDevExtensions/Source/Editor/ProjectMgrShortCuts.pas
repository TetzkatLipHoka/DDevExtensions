{******************************************************************************}
{*                                                                            *}
{* DDevExtensions                                                             *}
{*                                                                            *}
{* (C) 2006 Andreas Hausladen                                                 *}
{*                                                                            *}
{******************************************************************************}

unit ProjectMgrShortCuts;

{$I ..\DelphiExtension.inc}

interface

{
  Adds Ctrl+Up / Ctrl+Down shortcuts to the Project Manager tree that move the
  selected project earlier / later in the build order (the "Build Sooner" /
  "Build Later" local-menu commands). Pre-2010 IDEs only - RAD Studio 2010+
  rebuilt the Project Manager and provides this itself.

  Re-created for the D7 port from the old (unpublished) v2.x line; the original
  unit's source was lost, this is a fresh implementation. The mangled FormShow
  symbol and the buildSooner_Item / buildLater_Item menu names were recovered
  from the shipped 2011 D7 DLL and coreide70.bpl.
}

procedure InitPlugin(Unload: Boolean);

implementation

{$IF CompilerVersion = 15.0} // Delphi 7 only (verified symbol + menu names)

uses
  Windows, Messages, SysUtils, Classes, Controls, Forms, Menus,
  IDEHooks, Hooking;

const
  // TProjectManagerForm.FormShow(Sender: TObject) in coreide70.bpl
  FormShowSymbol = '@Projectfrm@TProjectManagerForm@FormShow$qqrp14System@TObject';
  sProjectTree = 'ProjectTree';
  sBuildSoonerItem = 'buildSooner_Item';
  sBuildLaterItem = 'buildLater_Item';

type
  { Subclasses the Project Manager tree's WindowProc to catch Ctrl+Up/Down. }
  TTreeKeyHook = class(TObject)
  private
    FForm: TCustomForm;
    FTree: TWinControl;
    FOrgWndProc: TWndMethod;
    procedure WndProc(var Message: TMessage);
  public
    constructor Create(AForm: TCustomForm; ATree: TWinControl);
    destructor Destroy; override;
  end;

var
  FormShowHook: TRedirectCode;
  Hook: TTreeKeyHook;

function FindMenuItemInItems(Item: TMenuItem; const AName: string): TMenuItem;
var
  I: Integer;
begin
  for I := 0 to Item.Count - 1 do
  begin
    if SameText(Item[I].Name, AName) then
    begin
      Result := Item[I];
      Exit;
    end;
    Result := FindMenuItemInItems(Item[I], AName);
    if Result <> nil then
      Exit;
  end;
  Result := nil;
end;

{ The build-order items are added to the tree's local menu on demand; they may
  be owned by the form or live only inside a popup menu, so search both. }
function FindBuildItem(Form: TCustomForm; const AName: string): TMenuItem;
var
  I: Integer;
  C: TComponent;
begin
  C := Form.FindComponent(AName);
  if C is TMenuItem then
  begin
    Result := TMenuItem(C);
    Exit;
  end;
  for I := 0 to Form.ComponentCount - 1 do
  begin
    C := Form.Components[I];
    if C is TPopupMenu then
      Result := FindMenuItemInItems(TPopupMenu(C).Items, AName)
    else if C is TMainMenu then
      Result := FindMenuItemInItems(TMainMenu(C).Items, AName)
    else
      Result := nil;
    if Result <> nil then
      Exit;
  end;
  Result := nil;
end;

procedure TriggerBuildOrder(Form: TCustomForm; Sooner: Boolean);
var
  Item: TMenuItem;
begin
  if Sooner then
    Item := FindBuildItem(Form, sBuildSoonerItem)
  else
    Item := FindBuildItem(Form, sBuildLaterItem);
  if (Item <> nil) and Item.Enabled and Item.Visible then
    Item.Click;
end;

{ TTreeKeyHook }

constructor TTreeKeyHook.Create(AForm: TCustomForm; ATree: TWinControl);
begin
  inherited Create;
  FForm := AForm;
  FTree := ATree;
  FOrgWndProc := ATree.WindowProc;
  ATree.WindowProc := WndProc;
end;

destructor TTreeKeyHook.Destroy;
begin
  if (FTree <> nil) and Assigned(FOrgWndProc) then
    FTree.WindowProc := FOrgWndProc;
  inherited Destroy;
end;

procedure TTreeKeyHook.WndProc(var Message: TMessage);
begin
  if (Message.Msg = WM_KEYDOWN) and
     ((Message.WParam = VK_UP) or (Message.WParam = VK_DOWN)) and
     (GetKeyState(VK_CONTROL) < 0) and
     (GetKeyState(VK_SHIFT) >= 0) and (GetKeyState(VK_MENU) >= 0) then
  begin
    TriggerBuildOrder(FForm, Message.WParam = VK_UP); // Up = build sooner
    Message.Result := 0;
    Exit; // swallow so the tree does not just move the selection
  end;
  FOrgWndProc(Message);
end;

procedure WireProjectManager(Form: TCustomForm);
var
  Tree: TComponent;
begin
  Tree := Form.FindComponent(sProjectTree);
  if not (Tree is TWinControl) then
    Exit;
  { PM form is created once and lives for the IDE session; re-wire only if the
    tree instance changed (defensive - normally it does not). }
  if (Hook <> nil) and (Hook.FTree = Tree) then
    Exit;
  FreeAndNil(Hook);
  Hook := TTreeKeyHook.Create(Form, TWinControl(Tree));
end;

procedure Hook_FormShow(Instance: TObject; Sender: TObject);
type
  TFormShowProc = procedure(Instance: TObject; Sender: TObject);
begin
  UnhookFunction(FormShowHook);
  try
    TFormShowProc(FormShowHook.RealProc)(Instance, Sender);
    if Instance is TCustomForm then
      WireProjectManager(TCustomForm(Instance));
  finally
    RehookFunction(@Hook_FormShow, FormShowHook);
  end;
end;

procedure InitPlugin(Unload: Boolean);
begin
  if not Unload then
    HookFunction(coreide_bpl, FormShowSymbol, @Hook_FormShow, FormShowHook)
  else
  begin
    UnhookFunction(FormShowHook);
    FreeAndNil(Hook);
  end;
end;

{$ELSE}

procedure InitPlugin(Unload: Boolean);
begin
  // RAD Studio 2010+ rebuilt the Project Manager and provides build-order
  // shortcuts itself; nothing to do here.
end;

{$IFEND}

end.
