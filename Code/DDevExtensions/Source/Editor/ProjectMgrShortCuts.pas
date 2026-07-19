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
  TControlAccess = class(TControl); // TControl.PopupMenu is protected

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

{ The build-order items are created lazily when the tree's local menu pops up
  (PopupMenu.OnPopup = TProjectManagerForm.LocalMenuPopup), so they do not exist
  until then. Fire OnPopup to build the menu for the current selection, then
  look the item up inside that menu. }
function FindBuildItemViaPopup(Menu: TPopupMenu; const AName: string): TMenuItem;
begin
  Result := nil;
  if Menu = nil then
    Exit;
  if Assigned(Menu.OnPopup) then
    Menu.OnPopup(Menu);
  Result := FindMenuItemInItems(Menu.Items, AName);
end;

function TriggerBuildOrder(Form: TCustomForm; Tree: TWinControl; Sooner: Boolean): Boolean;
var
  ItemName: string;
  Item: TMenuItem;
  I: Integer;
  C: TComponent;
begin
  Result := False;
  if Sooner then
    ItemName := sBuildSoonerItem
  else
    ItemName := sBuildLaterItem;

  { primary: the tree's own local menu }
  Item := FindBuildItemViaPopup(TControlAccess(Tree).PopupMenu, ItemName);

  { fallback: fire every popup menu on the form, then any already-built item }
  if Item = nil then
    for I := 0 to Form.ComponentCount - 1 do
    begin
      C := Form.Components[I];
      if C is TPopupMenu then
      begin
        Item := FindBuildItemViaPopup(TPopupMenu(C), ItemName);
        if Item <> nil then
          Break;
      end;
    end;

  if (Item <> nil) and Item.Enabled and Item.Visible then
  begin
    Item.Click;
    Result := True;
  end;
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
    // Up = build sooner. Only swallow the key if we actually acted, so plain
    // tree behavior is preserved when the command is unavailable.
    if TriggerBuildOrder(FForm, FTree, Message.WParam = VK_UP) then
    begin
      Message.Result := 0;
      Exit;
    end;
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
