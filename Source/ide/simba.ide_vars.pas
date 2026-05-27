{
  Author: Raymond van Venetië and Merlijn Wajer
  Project: Simba (https://github.com/MerlijnWajer/Simba)
  License: GNU General Public License (https://www.gnu.org/licenses/gpl-3.0)
  --------------------------------------------------------------------------
  Temporary IDE variables for the lifespan of the process
}
unit simba.ide_vars;

{$i simba.inc}

interface

uses
  Classes, SysUtils,
  simba.base, simba.process;

type
  TSimbaIDEVars = record
  private
    FProcessSelection: TProcessID;
    FWindowSelection: TWindowHandle;

    function GetWindowSelection: TWindowHandle;
    procedure SetWindowSelection(AValue: TWindowHandle);
  public
    property WindowSelection: TWindowHandle read GetWindowSelection write SetWindowSelection;
    property ProcessSelection: TProcessID read FProcessSelection write FProcessSelection;
  end;

var
  SimbaIDEVars: TSimbaIDEVars;

implementation

uses
  simba.vartype_windowhandle,
  simba.remoteinput_autopair;

function TSimbaIDEVars.GetWindowSelection: TWindowHandle;
begin
  if not FWindowSelection.IsValid() then
    FWindowSelection := GetDesktopWindow();
  Result := FWindowSelection;
end;

procedure TSimbaIDEVars.SetWindowSelection(AValue: TWindowHandle);
begin
  FWindowSelection := AValue;
  // Attempt to pair libremoteinput so IDE image-capture tools (ACA, DTM,
  // debug viewer) work on OpenGL-rendered targets like RuneLite + GPU plugin.
  // No-op for non-RuneLite targets or when libremoteinput64.dll is absent.
  RemoteInputAutoPair(AValue);
end;

end.


