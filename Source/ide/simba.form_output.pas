{
  Author: Raymond van Venetië and Merlijn Wajer
  Project: Simba (https://github.com/MerlijnWajer/Simba)
  License: GNU General Public License (https://www.gnu.org/licenses/gpl-3.0)
}
unit simba.form_output;

{$i simba.inc}

interface

uses
  classes, sysutils, forms, controls, comctrls, graphics, menus, extctrls, syncobjs,
  synedit, syneditmiscclasses, syneditmousecmds,
  simba.settings, simba.base, simba.component_tabcontrol, simba.component_synedit,
  simba.vartype_string, simba.ide_output_components;

type
  TSimbaOutputForm = class(TForm)
    ContextMenu: TPopupMenu;
    MenuItemCustomize: TMenuItem;
    MenuItemCopyAll: TMenuItem;
    MenuItemCopyLine: TMenuItem;
    MenuItemSeperator: TMenuItem;
    MenuItemCopy: TMenuItem;
    MenuItemSelectAll: TMenuItem;
    Separator1: TMenuItem;
    FlushTimer: TTimer;

    procedure ContextMenuMeasureItem(Sender: TObject; ACanvas: TCanvas; var AWidth, AHeight: Integer);
    procedure FormMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure FormMouseLeave(Sender: TObject);
    procedure FormMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure MenuItemCopyAllClick(Sender: TObject);
    procedure MenuItemCopyClick(Sender: TObject);
    procedure MenuItemCopyLineClick(Sender: TObject);
    procedure MenuItemCustomizeClick(Sender: TObject);
    procedure MenuItemSelectAllClick(Sender: TObject);
    procedure DoFlushTimerExecute(Sender: TObject);
  protected
    FTabControl: TSimbaTabControl;
    FSimbaOutputBox: TOutputListComponent;

    function CanAnchorDocking(X, Y: Integer): Boolean;

    procedure DoScriptTabChange(Sender: TObject);

    procedure DebugLn(const S: String);

    function GetActiveOutputBox: TOutputListComponent;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    property SimbaOutputBox: TOutputListComponent read FSimbaOutputBox;
    property ActiveOutputBox: TOutputListComponent read GetActiveOutputBox;

    function AddSimbaOutput: TOutputListComponent;
    function AddScriptOutput(TabTitle: String): TOutputListComponent;

    procedure MoveTab(AFrom, ATo: Integer);
  end;

var
  SimbaOutputForm: TSimbaOutputForm;

implementation

{$R *.lfm}

uses
  SynEditMarkupBracket, SynEditMarkupWordGroup,
  simba.ide_dockinghelpers, simba.misc,
  simba.form_main, simba.form_tabs,  simba.form_settings,
  simba.nativeinterface,
  simba.ide_tab, simba.ide_events, simba.ide_utils, simba.ide_codetools_base;

type
  TSimbaOutputTab = class(TSimbaTab)
  protected
    FOutputBox: TOutputListComponent;

    procedure DoTabScriptStateChange(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;

    property OutputBox: TOutputListComponent read FOutputBox;
  end;

procedure TSimbaOutputTab.DoTabScriptStateChange(Sender: TObject);
begin
  if (Sender is TSimbaScriptTab) and (TSimbaScriptTab(Sender).OutputBox = FOutputBox) then
  begin
    case TSimbaScriptTab(Sender).ScriptState of
      ESimbaScriptState.STATE_RUNNING: ImageIndex := IMG_PLAY;
      ESimbaScriptState.STATE_PAUSED:  ImageIndex := IMG_PAUSE;
      else
        ImageIndex := IMG_STOP;
    end;
  end;
end;

constructor TSimbaOutputTab.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);

  FOutputBox := TOutputListComponent.Create(Self);
  FOutputBox.Parent := Self;
  FOutputBox.Align := alClient;

  SimbaIDEEvents.Register(Self, SimbaIDEEvent.TAB_SCRIPTSTATE_CHANGE, @DoTabScriptStateChange);
end;

procedure TSimbaOutputForm.MenuItemSelectAllClick(Sender: TObject);
begin
  if (ContextMenu.PopupComponent is TSynEdit) then
    with TSynEdit(ContextMenu.PopupComponent) do
      SelectAll();
end;

procedure TSimbaOutputForm.DoFlushTimerExecute(Sender: TObject);
var
  I: Integer;
begin
  for I := 0 to FTabControl.TabCount - 1 do
    TSimbaOutputTab(FTabControl.Tabs[I]).OutputBox.Flush();
end;

function TSimbaOutputForm.GetActiveOutputBox: TOutputListComponent;
begin
  if (FTabControl.ActiveTab is TSimbaOutputTab) then
    Result := TSimbaOutputTab(FTabControl.ActiveTab).OutputBox
  else
    Result := nil;
end;

procedure TSimbaOutputForm.DebugLn(const S: String);
begin
  SimbaOutputBox.Add(S + LineEnding);
end;

function TSimbaOutputForm.AddSimbaOutput: TOutputListComponent;
var
  Tab: TSimbaOutputTab;
begin
  Tab := FTabControl.AddTab('Simba') as TSimbaOutputTab;
  Tab.ImageIndex := IMG_SIMBA;

  Result := Tab.OutputBox;
  Result.PopupMenu := ContextMenu;
end;

function TSimbaOutputForm.AddScriptOutput(TabTitle: String): TOutputListComponent;
var
  Tab: TSimbaOutputTab;
begin
  Tab := FTabControl.AddTab(TabTitle) as TSimbaOutputTab;

  Result := Tab.OutputBox;
  Result.PopupMenu := ContextMenu;
end;

procedure TSimbaOutputForm.MoveTab(AFrom, ATo: Integer);
begin
  FTabControl.MoveTab(AFrom + 1, ATo + 1); // + 1 because of Simba tab
end;

procedure TSimbaOutputForm.MenuItemCopyClick(Sender: TObject);
begin
  if (ContextMenu.PopupComponent is TSynEdit) then
    with TSynEdit(ContextMenu.PopupComponent) do
      CopyToClipboard();
end;

procedure TSimbaOutputForm.MenuItemCopyLineClick(Sender: TObject);
var
  Line: Integer;
begin
  if (ContextMenu.PopupComponent is TSynEdit) then
    with TSynEdit(ContextMenu.PopupComponent) do
    begin
      Line := PixelsToRowColumn(ScreenToClient(ContextMenu.PopupPoint), []).Y;
      if (Line > 0) and (Line <= Lines.Count) then
        DoCopyToClipboard(Lines[Line - 1]);
    end;
end;

procedure TSimbaOutputForm.MenuItemCopyAllClick(Sender: TObject);
begin
  if (ContextMenu.PopupComponent is TSynEdit) then
    with TSynEdit(ContextMenu.PopupComponent) do
      DoCopyToClipboard(Lines.Text);
end;

procedure TSimbaOutputForm.MenuItemCustomizeClick(Sender: TObject);
begin
  SimbaSettingsForm.Open('Output Box');
end;

function TSimbaOutputForm.CanAnchorDocking(X, Y: Integer): Boolean;
begin
  Result := FTabControl.InEmptySpace(X, Y) and (not FTabControl.Dragging);
end;

procedure TSimbaOutputForm.DoScriptTabChange(Sender: TObject);
begin
  //if (Sender is TSimbaScriptTab) then
  //  TSimbaScriptTab(Sender).OutputBox.MakeVisible();
end;

procedure TSimbaOutputForm.FormMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  if CanAnchorDocking(X, Y) and (HostDockSite is TSimbaAnchorDockHostSite) then
    TSimbaAnchorDockHostSite(HostDockSite).Header.MouseDown(Button, Shift, X, Y);
end;

procedure TSimbaOutputForm.ContextMenuMeasureItem(Sender: TObject; ACanvas: TCanvas; var AWidth, AHeight: Integer);
begin
  MenuItemHeight(Sender as TMenuItem, ACanvas, AHeight);
end;

procedure TSimbaOutputForm.FormMouseLeave(Sender: TObject);
begin
  if (HostDockSite is TSimbaAnchorDockHostSite) then
    TSimbaAnchorDockHostSite(HostDockSite).Header.MouseLeave();
end;

procedure TSimbaOutputForm.FormMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
begin
  if CanAnchorDocking(X, Y) and (HostDockSite is TSimbaAnchorDockHostSite) then
    TSimbaAnchorDockHostSite(HostDockSite).Header.MouseMove(Shift, X, Y);
end;

constructor TSimbaOutputForm.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);

  FTabControl := TSimbaTabControl.Create(Self, TSimbaOutputTab);
  FTabControl.Parent := Self;
  FTabControl.Align := alClient;
  FTabControl.CanAddTabOnDoubleClick := False;
  FTabControl.CanMoveTabs := False;
  FTabControl.ShowCloseButtons := False;

  FTabControl.OnMouseMove := @FormMouseMove;
  FTabControl.OnMouseDown := @FormMouseDown;
  FTabControl.OnMouseLeave := @FormMouseLeave;

  FSimbaOutputBox := AddSimbaOutput();

  SetCodetoolsMessageHandler(@DebugLn);
  OnDebugLn := @DebugLn;

  SimbaIDEEvents.Register(Self, SimbaIDEEvent.TAB_CHANGE, @DoScriptTabChange);
end;

destructor TSimbaOutputForm.Destroy;
begin
  OnDebugLn := nil;

  inherited Destroy();
end;

end.

