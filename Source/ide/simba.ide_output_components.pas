unit simba.ide_output_components;

{$i simba.inc}

interface

uses
  Classes, SysUtils, SynEdit, SynEditHighlighter, Graphics, SynEditTextBuffer,
  LazSynEditText, fgl, SynHighlighterPas, syncobjs, simba.containers,
  simba.component_synedit, Controls;

const
  CC_SET_BACKGROUND = UInt8(1);
  CC_RESET_BACKGROUND = UInt8(2);

type
  // the actual sequence that is encoded in the string
  // example for `setting red background` in character view: #0#0#1#255#0#0#0
  PControlCode = ^TControlCode;
  TControlCode = packed record
    Sig: array[0..1] of Char; // #0#0
    Typ: UInt8;
    Data: UInt32;
  end;

// Exposing TSynEdit is just a ton unrelated mess so just wrap it.
type
  TOutputListComponentReal = class(TCustomControl)
  private
    FListComponent: TComponent;
  public
    constructor Create(AOwner: TComponent); override;

    procedure Add(const S: String);
    procedure Flush;
  end;

implementation

uses
  SynEditTypes, SynEditMarkup, SynEditMiscClasses,
  simba.vartype_string, ATCanvasPrimitives, simba.component_theme;

type
  TLineControlCode = record
    Index: Int32; // column where this control code activates
    Typ: UInt8;
    Data: UInt32;
  end;
  TLineControlCodeArray = array of TLineControlCode;
  TLineControlCodes = specialize TFPGList<TLineControlCodeArray>;

type
  TOutputListComponent = class(TSimbaMemo)
  public type
    TPending = record
      Text: String;
      Codes: TLineControlCodeArray;
    end;
    TPendingList = specialize TSimbaList<TPending>;
  private
    FLock: TCriticalSection;
    FBuffer: String; // string buffer written to until a line ending exists
    FControlCodes: TLineControlCodes; // all line attributes, kept in sync with .Lines
    FControlCodeBuffer: TLineControlCodeArray; // buffer to write into when parsing a line

    FPending: TPendingList;

    procedure OnLineCountChange(Sender: TSynEditStrings; aIndex, aCount: Integer);
    procedure OnCleared(Sender: TSynEditStrings; aIndex, aCount: Integer);

    procedure ParseAndAddLine(const S: String);
  public
    constructor Create(AOwner: TComponent); reintroduce;
    destructor Destroy; override;

    function MakeColorAttribute(c: TColor): String;
    function MakeClearColorAttribute: String;

    procedure Add(const S: String);
    procedure Flush;
  end;

  TOutputHighlighter = class(TSynCustomHighlighter)
  protected
    FTokenPos: SizeInt;
    FTokenEnd: SizeInt;
    FLineText: String;
    FLineLength: SizeInt;
    FControlCodes: TLineControlCodeArray;
    FNextIndex: SizeInt;
    FColor: TColor;
    FSpecialAttri: TSynHighlighterAttributesModifier;
    FTest: TSynHighlighterAttributes;
  public
    procedure SetLine(const NewValue: String; LineNumber: Integer); override;
    procedure Next; override;
    function  GetEol: Boolean; override;
    procedure GetTokenEx(out TokenStart: PChar; out TokenLength: integer); override;
    function  GetTokenAttribute: TSynHighlighterAttributes; override;
  public
    constructor Create(AOwner: TComponent); override;

    function GetToken: String; override;
    function GetTokenPos: Integer; override;
    function GetTokenKind: integer; override;
    function GetDefaultAttribute(Index: integer): TSynHighlighterAttributes; override;
  end;

  // Handles coloring the whitespace after line text has finished.
  // Wasnt possible to do in highlighter to my knowledge
  // Note: In theory the highlighter could be removed and everything handled here
  //       however i did not know that at the time :)
  TEndOfLineWhitespaceMarkup = class(TSynEditMarkup)
  private
    FControlCodes: TLineControlCodes;
    FStart: Integer; // -1 will mean no markup
  public
    constructor Create(ASynEdit: TSynEditBase);

    procedure PrepareMarkupForRow(aRow: Integer); override;
    function GetMarkupAttributeAtRowCol(const aRow: Integer; const aStartCol: TLazSynDisplayTokenBound; const AnRtlInfo: TLazSynDisplayRtlInfo): TSynSelectedColor; override;
    procedure GetNextMarkupColAfterRowCol(const aRow: Integer; const aStartCol: TLazSynDisplayTokenBound;const AnRtlInfo: TLazSynDisplayRtlInfo; out ANextPhys, ANextLog: Integer); override;
    function GetMarkupAttributeAtWrapEnd(const aRow: Integer; const aWrapCol: TLazSynDisplayTokenBound): TSynSelectedColor; override;
  end;

constructor TEndOfLineWhitespaceMarkup.Create(ASynEdit: TSynEditBase);
begin
  inherited Create(ASynEdit);

  FControlCodes := TOutputListComponent(ASynEdit).FControlCodes;
end;

procedure TEndOfLineWhitespaceMarkup.PrepareMarkupForRow(aRow: Integer);
var
  ControlCodesForLine: TLineControlCodeArray;
  LastControlCode: TLineControlCode;
begin
  Assert(aRow-1 >= 0);
  Assert(aRow-1 < FControlCodes.Count);

  FStart := -1;

  ControlCodesForLine := FControlCodes[aRow-1];
  if (ControlCodesForLine <> nil) then
  begin
    LastControlCode := ControlCodesForLine[High(ControlCodesForLine)];
    if (LastControlCode.Typ = CC_SET_BACKGROUND) then
    begin
      MarkupInfo.Background := ColorBlend(LastControlCode.Data, SimbaComponentTheme.ColorBackground, 150);
      FStart := Length(Lines[aRow - 1]) + 1;
    end;
  end;
end;

function TEndOfLineWhitespaceMarkup.GetMarkupAttributeAtRowCol(const aRow: Integer; const aStartCol: TLazSynDisplayTokenBound; const AnRtlInfo: TLazSynDisplayRtlInfo): TSynSelectedColor;
begin
  if (FStart > -1) and (FStart <= aStartCol.Logical) then
    Result := MarkupInfo
  else
    Result := nil;
end;

function TEndOfLineWhitespaceMarkup.GetMarkupAttributeAtWrapEnd(const aRow: Integer; const aWrapCol: TLazSynDisplayTokenBound): TSynSelectedColor;
begin
  if (FStart > -1) and (FStart <= aWrapCol.Logical) then
    Result := MarkupInfo
  else
    Result := nil;
end;

procedure TEndOfLineWhitespaceMarkup.GetNextMarkupColAfterRowCol(const aRow: Integer; const aStartCol: TLazSynDisplayTokenBound; const AnRtlInfo: TLazSynDisplayRtlInfo; out ANextPhys, ANextLog: Integer);
begin
  ANextLog := -1;
  ANextPhys := -1;
  if (FStart > -1) and (FStart > aStartCol.Logical) then
    ANextLog := FStart;
end;

procedure TOutputListComponent.OnLineCountChange(Sender: TSynEditStrings; aIndex, aCount: Integer);
var
  i: Integer;
begin
  if (aCount < 0) then
    FControlCodes.DeleteRange((aindex + acount) + 1, aindex)
  else for i := aindex to (aindex + acount) - 1 do
    FControlCodes.Insert(i,nil);
end;

procedure TOutputListComponent.OnCleared(Sender: TSynEditStrings; aIndex, aCount: Integer);
begin
  FControlCodes.Clear();
end;

function TOutputListComponent.MakeColorAttribute(c: TColor): String;
begin
  SetLength(Result, SizeOf(TControlCode));
  with PControlCode(@Result[1])^ do
  begin
    Sig[0] := #0;
    Sig[1] := #0;
    Typ := CC_SET_BACKGROUND;
    Data := c;
  end;
end;

function TOutputListComponent.MakeClearColorAttribute: String;
begin
  SetLength(Result, SizeOf(TControlCode));
  with PControlCode(@Result[1])^ do
  begin
    Sig[0] := #0;
    Sig[1] := #0;
    Typ := CC_RESET_BACKGROUND;
    Data := 0;
  end;
end;

procedure TOutputListComponent.ParseAndAddLine(const S: String);

  procedure AddControlCode(var Count: Integer; const Index: UInt32; const Typ: UInt8; const Data: UInt32); inline;
  begin
    if (Count >= Length(FControlCodeBuffer)) then
      SetLength(FControlCodeBuffer, Length(FControlCodeBuffer) * 2);

    FControlCodeBuffer[Count].Typ := Typ;
    FControlCodeBuffer[Count].Data := Data;
    FControlCodeBuffer[Count].Index := Index;
    Inc(Count);
  end;

  function HasControlCodeSignature: Boolean;
  begin
    Result := (Length(S) >= SizeOf(TControlCode)) and (IndexWord(S[1], Length(S) div 2, 0) > -1);
  end;

var
  i, LastPos, Len, Stop: Integer;
  CleanTextLen: Integer;
  CleanText: AnsiString;
  ControlCodeCount: Integer;
  Last: TLineControlCode;
  PendingItem: TPending;
begin
  Len := Length(S);
  if (Len = 0) then
    Exit;

  ControlCodeCount := 0;
  Stop := Len - SizeOf(TControlCode) + 1;

  // carry-over last color from previous line
  if FPending.Count = 0 then
  begin
    if (Lines.Count > 0) and (FControlCodes[Lines.Count - 1] <> nil) then
    begin
      Last := FControlCodes[Lines.Count - 1][High(FControlCodes[Lines.Count - 1])];
      if (Last.Typ = CC_SET_BACKGROUND) then
        AddControlCode(ControlCodeCount, 0, Last.Typ, Last.Data);
    end;
  end else
  begin
    if (FPending.Last.Codes <> nil) then
    begin
      Last := FPending.Last.Codes[High(FPending.Last.Codes)];
      if (Last.Typ = CC_SET_BACKGROUND) then
        AddControlCode(ControlCodeCount, 0, Last.Typ, Last.Data);
    end;
  end;

  if HasControlCodeSignature() then
  begin
    SetLength(CleanText, Len);
    CleanTextLen := 0;
    LastPos := 1;
    i := 1;

    while (i <= Stop) do
    begin
      if (S[i] = #0) and (S[i+1] = #0) then
      begin
        if (i > LastPos) then
        begin
          Move(S[LastPos], CleanText[CleanTextLen + 1], i - LastPos);
          Inc(CleanTextLen, i - LastPos);
        end;
        AddControlCode(ControlCodeCount, CleanTextLen, PControlCode(@S[i])^.typ, PControlCode(@S[i])^.data);
        i := i + SizeOf(TControlCode);
        LastPos := i;
      end
      else
        Inc(i);
    end;

    // Remaining tail of the string
    if (LastPos <= Len) then
    begin
      Move(S[LastPos], CleanText[CleanTextLen + 1], Len - LastPos + 1);
      Inc(CleanTextLen, Len - LastPos + 1);
    end;
    SetLength(CleanText, CleanTextLen);
  end else
    CleanText := S;

  if (ControlCodeCount > 0) then
    PendingItem.Codes := Copy(FControlCodeBuffer, 0, ControlCodeCount)
  else
    PendingItem.Codes := nil;
  PendingItem.Text := CleanText;
  FPending.Add(PendingItem);
end;

procedure TOutputListComponent.Add(const S: String);
var
  Arr: TStringArray;
  I: Integer;
begin
  FLock.Enter();
  try
    Arr := String(FBuffer + S).Split(LineEnding, False);
    if (Length(Arr) = 0) then
      FBuffer := ''
    else if S.EndsWith(LineEnding) then
    begin
      FBuffer := '';
      for I := 0 to High(Arr) do
        ParseAndAddLine(Arr[I]);
    end else
    begin
      FBuffer := Arr[High(Arr)];
      for I := 0 to High(Arr) - 1 do
        ParseAndAddLine(Arr[I]);
    end;
  finally
    FLock.Leave();
  end;
end;

procedure TOutputListComponent.Flush;
var
  i,idx: Integer;
begin
  FLock.Enter();
  for i:=0 to FPending.Count-1 do
  begin
    idx := Lines.Add(FPending[i].Text);
    FControlCodes[idx] := FPending[i].Codes;
  end;
  FPending.Clear();
  FLock.Leave();
end;

constructor TOutputListComponent.Create(AOwner: TComponent);
begin
  inherited Create(AOwner, False);

  FLock := TCriticalSection.Create();
  FControlCodes := TLineControlCodes.Create();
  FBuffer := '';

  FPending := TPendingList.Create();

  SetLength(FControlCodeBuffer, 128);

  Highlighter := TOutputHighlighter.Create(Self);

  TextView.AddChangeHandler(senrLineCount, @OnLineCountChange);
  TextView.AddChangeHandler(senrCleared, @OnCleared);

  MarkupManager.AddMarkUp(TEndOfLineWhitespaceMarkup.Create(Self));
end;

destructor TOutputListComponent.Destroy;
begin
  inherited Destroy();

  FreeAndNil(FLock);
  FreeAndNil(FControlCodes);
  FreeAndNil(FPending);
end;

constructor TOutputHighlighter.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);

  FSpecialAttri := TSynHighlighterAttributesModifier.Create('special');
  FSpecialAttri.OnChange := nil;

  FTest := TSynHighlighterAttributes.Create('Test');
  FTest.OnChange := nil;
  FTest.Background := clGreen;
  FTest.FrameEdges := sfeNone;

  AddAttribute(FSpecialAttri);
  AddAttribute(FTest);
end;

procedure TOutputHighlighter.SetLine(const NewValue: String; LineNumber: Integer);
begin
  inherited;

  if (LineNumber < 0) or (LineNumber >= TOutputListComponent(Owner).FControlCodes.Count) then
    raise Exception.Create('TOutputHighlighter.SetLine out of range?');

  FControlCodes := TOutputListComponent(Owner).FControlCodes[LineNumber];
  FNextIndex := 0;
  FLineText := NewValue;
  FLineLength := Length(FLineText);
  FTokenEnd := 1;
  FColor := -1;
  Next();
end;

procedure TOutputHighlighter.Next;
begin
  FTokenPos := FTokenEnd;
  if (FTokenPos > FLineLength) then
  begin
    FTokenEnd := FLineLength + 1;
    Exit;
  end;

  if (FControlCodes <> nil) and (FNextIndex <= High(FControlCodes)) then
  begin
    FTokenEnd := FControlCodes[FNextIndex].Index + 1;
    if (FTokenPos = FTokenEnd) then
    begin
      if (FControlCodes[FNextIndex].Typ = CC_SET_BACKGROUND) then
        FColor := FControlCodes[FNextIndex].Data
      else
        FColor := -1;

      Inc(FNextIndex);
      if (FNextIndex <= High(FControlCodes)) then
        FTokenEnd := FControlCodes[FNextIndex].Index + 1
      else
        FTokenEnd := FLineLength + 1;
    end;
  end else
    FTokenEnd := FLineLength + 1;
end;

function TOutputHighlighter.GetEol: Boolean;
begin
  Result := FTokenPos > FLineLength;
end;

procedure TOutputHighlighter.GetTokenEx(out TokenStart: PChar; out TokenLength: integer);
begin
  TokenStart := @FLineText[FTokenPos];
  TokenLength := FTokenEnd - FTokenPos;
end;

function TOutputHighlighter.GetTokenAttribute: TSynHighlighterAttributes;
begin
  if (FColor = -1) then
    Result := nil
  else
  begin
    Result := FSpecialAttri;
    Result.Background := ColorBlend(FColor, SimbaComponentTheme.ColorBackground, 150);
  end;
end;

function TOutputHighlighter.GetToken: String;
begin
  Result := Copy(FLineText, FTokenPos, FTokenEnd - FTokenPos);
end;

function TOutputHighlighter.GetTokenPos: Integer;
begin
  Result := FTokenPos - 1;
end;

function TOutputHighlighter.GetDefaultAttribute(Index: integer): TSynHighlighterAttributes;
begin
  Result := FTest;
end;

function TOutputHighlighter.GetTokenKind: integer;
begin
  Result := -1;
end;

constructor TOutputListComponentReal.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);

  FListComponent := TOutputListComponent.Create(Self);
  TOutputListComponent(FListComponent).Parent := Self;
  TOutputListComponent(FListComponent).Align := alClient;
end;

procedure TOutputListComponentReal.Add(const S: String);
begin
  TOutputListComponent(FListComponent).Add(S);
end;

procedure TOutputListComponentReal.Flush;
begin
  TOutputListComponent(FListComponent).Flush();
end;

end.

