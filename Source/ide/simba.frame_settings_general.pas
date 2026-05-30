{
  Author: Raymond van Venetië and Merlijn Wajer
  Project: Simba (https://github.com/MerlijnWajer/Simba)
  License: GNU General Public License (https://www.gnu.org/licenses/gpl-3.0)
}
unit simba.frame_settings_general;

{$i simba.inc}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, StdCtrls, ComCtrls, ExtCtrls, Spin, DividerBevel,
  simba.base, simba.component_theme;

type
  TSimbaGeneralFrame = class(TFrame)
    Label1: TLabel;
    ToolbarSpacingSpinEdit: TSpinEdit;
    ToolbarPositionComboBox: TComboBox;
    DividerBevel1: TDividerBevel;
    DividerBevel2: TDividerBevel;
    PlaceholderLabel: TLabel;
    ScrollBarSizeLabel: TLabel;
    ScrollBarArrowSizeLabel: TLabel;
    ToolbarSizeCaption: TLabel;
    ToolbarSizeCaption1: TLabel;
    ToolbarSizeTrackBar: TTrackBar;
    ScrollBarSizeTrackBar: TTrackBar;
    ScrollBarArrowSizeTrackBar: TTrackBar;

    procedure ToolbarPositionComboBoxChange(Sender: TObject);
    procedure ToolbarSizeTrackBarChange(Sender: TObject);
    procedure DoScrollBarArrowTrackBarChange(Sender: TObject);
    procedure DoScrollBarTrackBarChange(Sender: TObject);
    procedure ToolbarSpacingSpinEditChange(Sender: TObject);
  private
    // Window-capture method selector, created in code (anchored, DPI-safe)
    // to avoid touching the designer .lfm.
    FCaptureDivider: TDividerBevel;
    FCaptureLabel: TLabel;
    FCaptureCombo: TComboBox;
    procedure DoCaptureMethodChange(Sender: TObject);
  protected
    procedure FontChanged(Sender: TObject); override;
  public
    constructor Create(AOwner: TComponent); override;

    procedure Load;
    procedure Save;
  end;

implementation

uses
  simba.settings,
  simba.misc,
  simba.ide_vars,
  simba.capture_wgc;

{$R *.lfm}

procedure TSimbaGeneralFrame.ToolbarPositionComboBoxChange(Sender: TObject);
begin
  case ToolbarPositionComboBox.ItemIndex of
    0: SimbaSettings.General.ToolbarPosition.Value := 'Top';
    1: SimbaSettings.General.ToolbarPosition.Value := 'Left';
    2: SimbaSettings.General.ToolbarPosition.Value := 'Right';
  end;
end;

procedure TSimbaGeneralFrame.DoScrollBarArrowTrackBarChange(Sender: TObject);
begin
  SimbaSettings.General.ScrollBarArrowSize.Value := ScrollBarArrowSizeTrackBar.Position;

  ScrollBarArrowSizeLabel.Caption := IfThen(
    SimbaSettings.General.ScrollBarArrowSize.IsDefault(),
    'Arrow Size: Default',
    'Arrow Size: ' + IntToStr(ScrollBarArrowSizeTrackBar.Position)
  );
end;

procedure TSimbaGeneralFrame.ToolbarSizeTrackBarChange(Sender: TObject);
begin
  SimbaSettings.General.ToolbarSize.Value := ToolbarSizeTrackBar.Position;

  ToolbarSizeCaption.Caption := IfThen(
    SimbaSettings.General.ToolbarSize.IsDefault(),
    'Size: Default',
    'Size: ' + IntToStr(ToolbarSizeTrackBar.Position)
  );
end;

procedure TSimbaGeneralFrame.DoScrollBarTrackBarChange(Sender: TObject);
begin
  SimbaSettings.General.ScrollBarSize.Value := ScrollBarSizeTrackBar.Position;

  ScrollBarSizeLabel.Caption := IfThen(
    SimbaSettings.General.ScrollBarSize.IsDefault(),
    'Size: Default',
    'Size: ' + IntToStr(ScrollBarSizeTrackBar.Position)
  );
end;

procedure TSimbaGeneralFrame.ToolbarSpacingSpinEditChange(Sender: TObject);
begin
  SimbaSettings.General.ToolBarSpacing.Value := ToolbarSpacingSpinEdit.Value;
end;

procedure TSimbaGeneralFrame.DoCaptureMethodChange(Sender: TObject);
begin
  // 0 = BitBlt, 1 = WGC.
  SimbaSettings.Capture.Method.Value := FCaptureCombo.ItemIndex;

  // Apply live so no restart is needed: re-run AutoOpen for the IDE's current
  // target. WGCAutoOpen reads the new value -- BitBlt releases the WGC session
  // (removing the yellow border), WGC opens a fresh one. GetWindowImage already
  // reads the setting per-call, so the capture path itself was already live;
  // this just fixes the lingering/absent WGC session on the active target.
  WGCAutoOpen(SimbaIDEVars.WindowSelection);
end;

procedure TSimbaGeneralFrame.FontChanged(Sender: TObject);
begin
  inherited FontChanged(Sender);

  PlaceholderLabel.Font := Self.Font;
  PlaceholderLabel.Font.Color := clForm;
end;

constructor TSimbaGeneralFrame.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);

  PlaceholderLabel.Font.Color := clForm;

  FCaptureDivider := TDividerBevel.Create(Self);
  FCaptureDivider.Parent := Self;
  FCaptureDivider.Caption := 'Capture';
  FCaptureDivider.AnchorSideLeft.Control := Self;
  FCaptureDivider.AnchorSideTop.Control := ScrollBarArrowSizeTrackBar;
  FCaptureDivider.AnchorSideTop.Side := asrBottom;
  FCaptureDivider.AnchorSideRight.Control := Self;
  FCaptureDivider.AnchorSideRight.Side := asrBottom;
  FCaptureDivider.Anchors := [akTop, akLeft, akRight];
  FCaptureDivider.BorderSpacing.Top := 16;
  FCaptureDivider.BorderSpacing.Right := 24;

  FCaptureLabel := TLabel.Create(Self);
  FCaptureLabel.Parent := Self;
  FCaptureLabel.Caption := 'Window capture method:';
  FCaptureLabel.AnchorSideLeft.Control := FCaptureDivider;
  FCaptureLabel.AnchorSideTop.Control := FCaptureDivider;
  FCaptureLabel.AnchorSideTop.Side := asrBottom;
  FCaptureLabel.Anchors := [akTop, akLeft];
  FCaptureLabel.BorderSpacing.Top := 16;

  FCaptureCombo := TComboBox.Create(Self);
  FCaptureCombo.Parent := Self;
  FCaptureCombo.Style := csDropDownList;
  FCaptureCombo.Items.Add('BitBlt (no GPU/OpenGL windows, no border)');
  FCaptureCombo.Items.Add('WGC (GPU/OpenGL windows; yellow border on Win10)');
  FCaptureCombo.AnchorSideLeft.Control := FCaptureLabel;
  FCaptureCombo.AnchorSideLeft.Side := asrBottom;
  FCaptureCombo.AnchorSideTop.Control := FCaptureLabel;
  FCaptureCombo.AnchorSideTop.Side := asrCenter;
  FCaptureCombo.Anchors := [akTop, akLeft];
  FCaptureCombo.BorderSpacing.Left := 16;
  FCaptureCombo.Width := 560;
  FCaptureCombo.OnChange := @DoCaptureMethodChange;
end;

procedure TSimbaGeneralFrame.Load;
begin
  case String(SimbaSettings.General.ToolbarPosition.Value) of
    'Top':   ToolbarPositionComboBox.ItemIndex := 0;
    'Left':  ToolbarPositionComboBox.ItemIndex := 1;
    'Right': ToolbarPositionComboBox.ItemIndex := 2;
  end;

  ToolbarSizeTrackBar.Position := SimbaSettings.General.ToolbarSize.Value;
  ToolbarSpacingSpinEdit.Value := SimbaSettings.General.ToolBarSpacing.Value;

  ScrollBarSizeTrackBar.Position := SimbaSettings.General.ScrollBarSize.Value;
  ScrollBarArrowSizeTrackBar.Position := SimbaSettings.General.ScrollBarArrowSize.Value;

  if (SimbaSettings.Capture.Method.Value = 0) then
    FCaptureCombo.ItemIndex := 0
  else
    FCaptureCombo.ItemIndex := 1;
end;

procedure TSimbaGeneralFrame.Save;
begin
  { nothing }
end;

end.

