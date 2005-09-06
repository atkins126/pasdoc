{
  @lastmod(2003-03-29)
  @author(Johannes Berg <johannes@sipsolutions.de>)
  @author(Ralf Junker (delphi@zeitungsjunge.de))
  @author(Marco Schmidt (marcoschmidt@geocities.com))
  @author(Michalis Kamburelis)

  @abstract(Provides a simplified Pascal scanner.)
  
  The scanner object @link(TScanner) returns tokens from a Pascal language
  character input stream. It uses the @link(PasDoc_Tokenizer) unit to get tokens,
  regarding conditional directives that might lead to including another files
  or will add or delete conditional symbols. Also handles FPC macros
  (when HandleMacros is true). So, this scanner is a combined
  tokenizer and pre-processor. }

unit PasDoc_Scanner;

{$I DEFINES.INC}

interface

uses
  SysUtils,
  Classes,
  PasDoc_Types,
  PasDoc_Tokenizer,
  StringVector,
  PasDoc_StringPairVector;

const
  { maximum number of streams we can recurse into; first one is the unit
    stream, any other stream an include file; current value is 32, increase
    this if you have more include files recursively including others }
  MAX_TOKENIZERS = 32;

type
  { subrange type that has the 26 lower case letters from a to z }
  TUpperCaseLetter = 'A'..'Z';
  { an array of boolean values, index type is @link(TUpperCaseLetter) }
  TSwitchOptions = array[TUpperCaseLetter] of Boolean;

  { This class scans one unit using one or more @link(TTokenizer) objects
    to scan the unit and all nested include files. }
  TScanner = class(TObject)
  private
    FCurrentTokenizer: Integer;
    FDirectiveLevel: Integer;
    FErrorMessage: string;
    FTokenizers: array[0..MAX_TOKENIZERS - 1] of TTokenizer;
    FSwitchOptions: TSwitchOptions;
    FBufferedToken: TToken;
    
    { For each symbol: 
        Name is the unique Name,
        Value is the string to be expanded into (in case of a macro),
        LongBool(Data) says if this is a macro 
          (i.e. should it be expanded). 
          
      Note the important fact: we can't use Value <> '' to decide
      if symbol is a macro. A non-macro symbol is something
      different than a macro that expands to nothing. }
    FSymbols: TStringPairVector;
    
    FIncludeFilePaths: TStringVector;
    FOnMessage: TPasDocMessageEvent;
    FVerbosity: Cardinal;
    FHandleMacros: boolean;

    { Removes symbol Name from the internal list of symbols.
      If Name was not in that list, nothing is done. }
    procedure DeleteSymbol(const Name: string);
    
    { Returns if a given symbol Name is defined at the moment. }
    function IsSymbolDefined(const Name: string): Boolean;
    
    function IsSwitchDefined(n: string): Boolean;
    function OpenIncludeFile(const n: string): Boolean;
    function SkipUntilElseOrEndif(out FoundElse: Boolean): Boolean;
    procedure ResolveSwitchDirectives(const Comment: String);
  protected
    procedure DoError(const AMessage: string; const AArguments: array of
      const; const AExitCode: Word);
    procedure DoMessage(const AVerbosity: Cardinal; const MessageType:
      TMessageType; const AMessage: string; const AArguments: array of const);
  public
    { Creates a TScanner object that scans the given input stream. }
    constructor Create(
      const s: TStream;
      const OnMessageEvent: TPasDocMessageEvent;
      const VerbosityLevel: Cardinal;
      const AStreamName: string;
      const AHandleMacros: boolean);
    destructor Destroy; override;

    { Adds Name to the list of symbols (as a normal symbol, not macro). }
    procedure AddSymbol(const Name: string);
    
    { Adds all symbols in the NewSymbols collection by calling
      @link(AddSymbol) for each of the strings in that collection. }
    procedure AddSymbols(const NewSymbols: TStringVector);
    
    { Adds Name as a symbol that is a macro, that expands to Value. }
    procedure AddMacro(const Name, Value: string);
    
    { Gets next token and throws it away. }
    procedure ConsumeToken;

    { Returns next token as parameter. Returns true on success, false on error. }
    function GetToken(var t: TToken): Boolean;
    { Returns the name of the file that is currently processed and the line
      number. Good for meaningful error messages. }
    function GetStreamInfo: string;
    property IncludeFilePaths: TStringVector read FIncludeFilePaths write
      FIncludeFilePaths;
    function PeekToken(var t: TToken): Boolean;
    procedure UnGetToken(var t: TToken);

    property OnMessage: TPasDocMessageEvent read FOnMessage write FOnMessage;
    property Verbosity: Cardinal read FVerbosity write FVerbosity;
    property SwitchOptions: TSwitchOptions read FSwitchOptions;
    
    property HandleMacros: boolean read FHandleMacros;
  end;

implementation

uses Utils;

type
  { all directives a scanner is going to regard }
  TDirectiveType = (DT_UNKNOWN, DT_DEFINE, DT_ELSE, DT_ENDIF, DT_IFDEF, 
    DT_IFNDEF, DT_IFOPT, DT_INCLUDE_FILE, DT_UNDEF, DT_INCLUDE_FILE_2);

const
  DirectiveNames: array[DT_DEFINE..High(TDirectiveType)] of string =
  ( 'DEFINE', 'ELSE', 'ENDIF', 'IFDEF', 'IFNDEF', 'IFOPT', 'I', 'UNDEF', 
    'INCLUDE' );

{ ---------------------------------------------------------------------------- }

(*Assumes that CommentContent is taken from a Token.CommentContent where
  Token.MyType was TOK_DIRECTIVE.
  
  Extracts DirectiveName and DirectiveParam from CommentContent.
  DirectiveName is the thing right after $ sign, uppercased.
  DirectiveParam is what followed after DirectiveName.
  E.g. for CommentContent = {$define My_Symbol} we get
  DirectiveName = 'DEFINE' and
  DirectiveParam = 'My_Symbol'.
  
  If ParamsEndedByWhitespace then Params end at the 1st
  whitespace. Else Params end when CommentContent ends.
  This is useful: usually ParamsEndedByWhitespace = true,
  e.g. {$ifdef foo bar xyz} is equivalent to {$ifdef foo}
  (bar and xyz are simply ignored by Pascal compilers).
  When using FPC and macro is off, or when using other compilers,
  {$define foo := bar xyz} means just {$define foo}.
  However when using FPC and macro is on,
  then {$define foo := bar xyz} means "define foo as a macro
  that expands to ``bar xyz'', so in this case you will need to use
  SplitDirective with ParamsEndedByWhitespace = false.
*)
function SplitDirective(const CommentContent: string; 
  const ParamsEndedByWhitespace: boolean;
  out DirectiveName, Params: string): Boolean;
var
  i: Integer;
  l: Integer;
begin
  Result := False;
  DirectiveName := '';
  Params := '';

  l := Length(CommentContent);

  { skip dollar sign from CommentContent }
  i := 2;
  if i > l then Exit;

  { get directive name }
  while (i <= l) and (CommentContent[i] <> ' ') do
  begin
    DirectiveName := DirectiveName + UpCase(CommentContent[i]);
    Inc(i);
  end;
  Result := True;

  { skip spaces }
  while (i <= l) and (CommentContent[i] = ' ') do
    Inc(i);
  if i > l then Exit;

  { get parameters - no conversion to uppercase here, it could be an include
    file name whose name need not be changed (platform.inc <> PLATFORM.INC) }
  while (i <= l) and 
    ((not ParamsEndedByWhitespace) or (CommentContent[i] <> ' ')) do
  begin
    Params := Params + CommentContent[i];
    Inc(i);
  end;
end;

{ First, splits CommentContent like SplitDirective.
  
  Then returns true and sets Dt to appropriate directive type,
  if DirectiveName was something known (see array DirectiveNames).
  Else returns false. }
function IdentifyDirective(const CommentContent: string;  
  out dt: TDirectiveType; out DirectiveName, DirectiveParam: string): Boolean;
var
  i: TDirectiveType;
begin
  Result := false;
  if SplitDirective(CommentContent, true, DirectiveName, DirectiveParam) then 
  begin
    for i := DT_DEFINE to High(TDirectiveType) do 
    begin
      if UpperCase(DirectiveName) = DirectiveNames[i] then 
      begin
        dt := i;
        Result := True;
        break;
      end;
    end;
  end;
end;

{ ---------------------------------------------------------------------------- }
{ TScanner }
{ ---------------------------------------------------------------------------- }

constructor TScanner.Create(
  const s: TStream;
  const OnMessageEvent: TPasDocMessageEvent;
  const VerbosityLevel: Cardinal;
  const AStreamName: string;
  const AHandleMacros: boolean);
var
  c: TUpperCaseLetter;
begin
  inherited Create;
  FOnMessage := OnMessageEvent;
  FVerbosity := VerbosityLevel;
  FHandleMacros := AHandleMacros;

  { Set default switch directives (according to the Delphi 4 Help). }
  for c := Low(SwitchOptions) to High(SwitchOptions) do
    FSwitchOptions[c] := False;
  FSwitchOptions['A'] := True;
  FSwitchOptions['C'] := True;
  FSwitchOptions['D'] := True;
  FSwitchOptions['G'] := True;
  FSwitchOptions['H'] := True;
  FSwitchOptions['I'] := True;
  FSwitchOptions['J'] := True;
  FSwitchOptions['L'] := True;
  FSwitchOptions['P'] := True;
  FSwitchOptions['O'] := True;
  FSwitchOptions['V'] := True;
  FSwitchOptions['X'] := True;

  FSymbols := TStringPairVector.Create(true);

  FTokenizers[0] := TTokenizer.Create(s, OnMessageEvent, VerbosityLevel, AStreamName);
  FCurrentTokenizer := 0;
  FBufferedToken := nil;
end;

{ ---------------------------------------------------------------------------- }

destructor TScanner.Destroy;
var
  i: Integer;
begin
  FSymbols.Free;

  for i := 0 to FCurrentTokenizer do begin
    FTokenizers[i].Free;
  end;

  FBufferedToken.Free;
  
  inherited;
end;

{ ---------------------------------------------------------------------------- }

const
  SymbolIsNotMacro = nil;
  SymbolIsMacro = Pointer(1);

procedure TScanner.AddSymbol(const Name: string);
begin
  if not IsSymbolDefined(Name) then 
  begin
    DoMessage(6, mtInformation, 'Symbol "%s" defined', [Name]);
    FSymbols.Add(TStringPair.Create(Name, '', SymbolIsNotMacro));
  end;
end;

{ ---------------------------------------------------------------------------- }

procedure TScanner.AddSymbols(const NewSymbols: TStringVector);
var
  i: Integer;
begin
  if NewSymbols <> nil then
    for i := 0 to NewSymbols.Count - 1 do
      AddSymbol(NewSymbols[i])
end;

{ ---------------------------------------------------------------------------- }

procedure TScanner.AddMacro(const Name, Value: string);
var 
  i: Integer;
begin
  i := FSymbols.FindName(Name);
  if i = -1 then
  begin
    DoMessage(6, mtInformation, 'Macro "%s" defined as "%s"', [Name, Value]);
    FSymbols.Add(TStringPair.Create(Name, Value, SymbolIsMacro));
  end else
  begin
    DoMessage(6, mtInformation, 'Macro "%s" RE-defined as "%s"', [Name, Value]);
    { Redefine macro in this case. }
    FSymbols.Items[i].Value := Value;
  end;
end;

{ ---------------------------------------------------------------------------- }

procedure TScanner.ConsumeToken;
begin
  FBufferedToken := nil;
end;

{ ---------------------------------------------------------------------------- }

procedure TScanner.DeleteSymbol(const Name: string);
begin
  FSymbols.DeleteName(Name);
end;

{ ---------------------------------------------------------------------------- }

function TScanner.GetStreamInfo: string;
begin
  if (FCurrentTokenizer >= 0) then begin
    Result := FTokenizers[FCurrentTokenizer].GetStreamInfo
  end else begin
    Result := '';
  end;
end;

{ ---------------------------------------------------------------------------- }

function TScanner.GetToken(var t: TToken): Boolean;

  { Call this when token T contains $define directive }
  procedure HandleDefineDirective(DirectiveParam: string);
  var 
    TempDirectiveName: string;
    i: Integer;
    SymbolName: string;
  begin
    if not HandleMacros then
      AddSymbol(DirectiveParam) else
    begin
      { Split T.CommentContent once again (this time with
        ParamsEndedByWhitespace = false. Then check is it macro. }
      SplitDirective(t.CommentContent, false, 
        TempDirectiveName, DirectiveParam);

      i := 1;
      while SCharIs(DirectiveParam, i, ['a'..'z', 'A'..'Z', '1'..'9', '_']) do
        Inc(i);
        
      SymbolName := Copy(DirectiveParam, 1, i - 1);
        
      while SCharIs(DirectiveParam, i, WhiteSpace) do
        Inc(i);
        
      if Copy(DirectiveParam, i, 2) = ':=' then
        AddMacro(SymbolName, Copy(DirectiveParam, i + 2, MaxInt)) else
        AddSymbol(SymbolName);
    end;
  end;

var
  dt: TDirectiveType;
  Finished: Boolean;
  FoundElse: Boolean;
  DirectiveName, DirectiveParam: string;
begin
  Assert(t = nil);
  if Assigned(FBufferedToken) then begin
    { we have a token buffered, we'll return this one }
    t := FBufferedToken;
    FBufferedToken := nil;
    Result := True;
    Exit;
  end;
  Result := False;
  Finished := False;
  repeat
    { check if we have a tokenizer left }
    if (FCurrentTokenizer = -1) then
      DoError('End of stream reached while trying to get next token.', [], 0);

    if FTokenizers[FCurrentTokenizer].HasData then begin
        { get next token from tokenizer }
      t := FTokenizers[FCurrentTokenizer].GetToken;
        { check if token is a directive }
      if (t.MyType = TOK_DIRECTIVE) then begin
        if not IdentifyDirective(t.CommentContent, 
          dt, DirectiveName, DirectiveParam) then 
        begin
          ResolveSwitchDirectives(t.Data);
          t.Free;
          Continue;
        end;
        case dt of
          DT_DEFINE: HandleDefineDirective(DirectiveParam);
          DT_ELSE: begin
              DoMessage(5, mtInformation, 'ELSE encountered', []);
              if (FDirectiveLevel > 0) then begin
                if not SkipUntilElseOrEndif(FoundElse) then Exit;
                if not FoundElse then Dec(FDirectiveLevel);
              end
              else begin
                FErrorMessage := GetStreamInfo + ': unexpected $ELSE directive.';
                Exit;
              end;
            end;
          DT_ENDIF: begin
              DoMessage(5, mtInformation, 'ENDIF encountered', []);
              if (FDirectiveLevel > 0) then begin
                Dec(FDirectiveLevel);
                DoMessage(6, mtInformation, 'FDirectiveLevel = ' + IntToStr(FDirectiveLevel), []);
              end
              else begin
                FErrorMessage := GetStreamInfo + ': unexpected $ENDIF directive.';
                Exit;
              end;
            end;
          DT_IFDEF: begin
              if IsSymbolDefined(DirectiveParam) then begin
                Inc(FDirectiveLevel);
                DoMessage(6, mtInformation, 'IFDEF encountered (%s), defined, level %d', [DirectiveParam, FDirectiveLevel]);
              end
              else begin
                DoMessage(6, mtInformation, 'IFDEF encountered (%s), not defined, level %d', [DirectiveParam, FDirectiveLevel]);
                if not SkipUntilElseOrEndif(FoundElse) then Exit;
                if FoundElse then
                  Inc(FDirectiveLevel);
              end;
            end;
          DT_IFNDEF: begin
              if not IsSymbolDefined(DirectiveParam) then begin
                Inc(FDirectiveLevel);
                DoMessage(6, mtInformation, 'IFNDEF encountered (%s), not defined, level %d', [DirectiveParam, FDirectiveLevel]);
              end
              else begin
                DoMessage(6, mtInformation, 'IFNDEF encountered (%s), defined, level %d', [DirectiveParam, FDirectiveLevel]);
                if not SkipUntilElseOrEndif(FoundElse) then Exit;
                if FoundElse then
                  Inc(FDirectiveLevel);
              end;
            end;
          DT_IFOPT: begin
              if (not IsSwitchDefined(DirectiveParam)) then begin
                if (not SkipUntilElseOrEndif(FoundElse)) then Exit;
                if FoundElse then Inc(FDirectiveLevel);
              end
              else
                Inc(FDirectiveLevel);
            end;
          DT_INCLUDE_FILE, DT_INCLUDE_FILE_2:
            if not OpenIncludeFile(DirectiveParam) then
              DoError(GetStreamInfo + ': Error, could not open include file "'
                + DirectiveParam + '"', [], 0);
          DT_UNDEF: begin
              DoMessage(6, mtInformation, 'UNDEF encountered (%s)', [DirectiveParam]);
              DeleteSymbol(DirectiveParam);
            end;
        end;
      end;
      if t.MyType = TOK_DIRECTIVE then begin
        t.Free;
        t := nil;
      end else begin
        Finished := True;
      end;
    end else begin
      DoMessage(5, mtInformation, 'Closing file "%s"', 
        [FTokenizers[FCurrentTokenizer].GetStreamInfo]);
      FTokenizers[FCurrentTokenizer].Free;
      FTokenizers[FCurrentTokenizer] := nil;
      Dec(FCurrentTokenizer);
    end;
  until Finished;
  Result := True;
end;

{ ---------------------------------------------------------------------------- }

function TScanner.IsSymbolDefined(const Name: string): Boolean;
begin
  Result := FSymbols.FindName(Name) <> -1;
end;

{ ---------------------------------------------------------------------------- }

function TScanner.IsSwitchDefined(N: string): Boolean;
begin
  { We expect a length 2 AnsiString like 'I+' or 'A-', first character a letter,
    second character plus or minus }
  if Length(N) >= 2 then
    begin;
      if (N[1] >= 'a') and (N[1] <= 'z') then
        N[1] := AnsiChar(Ord(N[1]) - 32);
      if (N[1] >= 'A') and (N[1] <= 'Z') and ((N[2] = '-') or (N[2] = '+')) then
        begin
          Result := FSwitchOptions[N[1]] = (N[2] = '+');
          Exit;
        end;
    end;
 
  DoMessage(2, mtInformation, GetStreamInfo + ': Invalid $IFOPT parameter (%s).', [N]);
  Result := False;
end;

{ ---------------------------------------------------------------------------- }

function TScanner.OpenIncludeFile(const n: string): Boolean;
var
  i: Integer;
  Name: string;
  NumAttempts: Integer;
  p: string;
  s: TStream;
begin
  { check if maximum number of FTokenizers has been reached }
  if FCurrentTokenizer = MAX_TOKENIZERS - 1 then begin
    DoError('%s: maximum number of FTokenizers reached.', [GetStreamInfo], 0);
  end;

  { determine how many names we can check; number is 1 + IncludeFilePaths.Count }
  NumAttempts := 1;

  if IncludeFilePaths <> nil then
    Inc(NumAttempts, IncludeFilePaths.Count);

  s := nil;
  { loop until we have checked all names or one attempt was successful }
  for i := 0 to NumAttempts - 1 do begin
    if i = 0 then
      Name := n
    else begin
      p := IncludeFilePaths[i - 1];
      if p <> '' then
        Name := p + n
      else
        Continue; { next loop iteration }
    end;
    DoMessage(5, mtInformation, 'Trying to open include file "%s"...', [Name]);
    if FileExists(Name) then begin
      s := TFileStream.Create(Name, fmOpenRead);
    end;
    if Assigned(s) then Break;
  end;

  { if we still don't have a valid open stream we failed }
  if not Assigned(s) then begin
    DoError('%s: could not open include file %s', [GetStreamInfo, n], 0);
  end;

  { create new tokenizer with stream }
  Inc(FCurrentTokenizer);
  FTokenizers[FCurrentTokenizer] := TTokenizer.Create(s, FOnMessage, FVerbosity, Name);

  Result := True;
end;

{ ---------------------------------------------------------------------------- }

function TScanner.PeekToken(var t: TToken): Boolean;
begin
  if GetToken(t) then begin
    FBufferedToken := t;
    Result := True;
  end else begin
    Result := False;
  end;
end;

{ ---------------------------------------------------------------------------- }

function TScanner.SkipUntilElseOrEndif(out FoundElse: Boolean): Boolean;
var
  dt: TDirectiveType;
  Level: Integer;
  DirectiveName, DirectiveParam: string;
  t: TToken;
  TT: TTokenType;
begin
//  Result := False; // no hint
  Level := 1;
  repeat
    t := FTokenizers[FCurrentTokenizer].SkipUntilCompilerDirective;
    if t = nil then begin
      DoError('SkipUntilElseOrEndif GetToken', [], 0);
    end;

    if (t.MyType = TOK_DIRECTIVE) then begin
      if IdentifyDirective(t.CommentContent, 
        dt, DirectiveName, DirectiveParam) then 
      begin
        DoMessage(6, mtInformation, 'SkipUntilElseOrFound: encountered directive %s', [DirectiveNames[dt]]);
        case dt of
          DT_IFDEF,
            DT_IFNDEF,
            DT_IFOPT: Inc(Level);
          DT_ELSE:
            { RJ: We must jump over all nested $IFDEFs until its $ENDIF is
              encountered, ignoring all $ELSEs. We must therefore not
              decrement Level at $ELSE if it is part of such a nested $IFDEF.
              $ELSE must decrement Level only for the initial $IFDEF.
              That's why whe test Level for 1 (initial $IFDEF) here. }
            if Level = 1 then Dec(Level);
          DT_ENDIF: Dec(Level);
        end;
      end;
    end;
    TT := t.MyType;
    t.Free;
  until (Level = 0) and (TT = TOK_DIRECTIVE) and ((dt = DT_ELSE) or (dt =
    DT_ENDIF));
  FoundElse := (dt = DT_ELSE);
  if FoundElse then begin
    DirectiveParam := 'ELSE'
  end else begin
    DirectiveParam := 'ENDIF';
  end;
  DoMessage(6, mtInformation, 'Skipped code, last token ' + DirectiveParam, []);
  Result := True;
end;

{ ---------------------------------------------------------------------------- }

procedure TScanner.UnGetToken(var t: TToken);
begin
  if Assigned(FBufferedToken) then
    DoError('%s: FATAL ERROR - CANNOT UNGET MORE THAN ONE TOKEN.',
      [GetStreamInfo], 0);

  FBufferedToken := t;
  t := nil;
end;

{ ---------------------------------------------------------------------------- }

procedure TScanner.DoError(const AMessage: string; const AArguments: array of
  const; const AExitCode: Word);
begin
  raise EPasDoc.Create(AMessage, AArguments, AExitCode);
end;

{ ---------------------------------------------------------------------------- }

procedure TScanner.DoMessage(const AVerbosity: Cardinal; const MessageType:
  TMessageType; const AMessage: string; const AArguments: array of const);
begin
  if Assigned(FOnMessage) then
    FOnMessage(MessageType, Format(AMessage, AArguments), AVerbosity);
end;

{ ---------------------------------------------------------------------------- }

procedure TScanner.ResolveSwitchDirectives(const Comment: String);
var
  p: PChar;
  l: Cardinal;
  c: Char;

  procedure SkipWhiteSpace;
  begin
    while (l > 0) and (p^ <= #32) do
      begin
        Inc(p);
        Dec(l);
      end;
  end;

begin
  p := Pointer(Comment);
  l := Length(Comment);
                                                                                                                               
  if l < 4 then Exit;
  case p^ of
    '{':
      begin
        if p[1] <> '$' then Exit;
        Inc(p, 2);
        Dec(l, 2);
      end;
    '(':
      begin
        if (p[1] <> '*') or (p[2] <> '$') then Exit;
        Inc(p, 3);
        Dec(l, 3);
      end;
  else
    Exit;
  end;
 
  repeat
    SkipWhiteSpace;
    if l < 3 then Exit;
 
    c := p^;
    if c in ['a'..'z'] then
      Dec(c, 32);
 
    if not (c in ['A'..'Z']) or not (p[1] in ['-', '+']) then
      Exit;
 
    FSwitchOptions[c] := p[1] = '+';
    Inc(p, 2);
    Dec(l, 2);
                                                                                                                               
    SkipWhiteSpace;
                                                                                                                               
    // Skip comma
    if (l = 0) or (p^ <> ',') then Exit;
    Inc(p);
    Dec(l);
  until False;
end;

end.
