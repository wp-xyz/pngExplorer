{ https://www.libpng.org/pub/png/spec/1.2/PNG-Chunks.html }

unit pngMain;

{$mode objfpc}{$H+}

interface

uses
  // RTL, FCL
  Classes, SysUtils, Contnrs, StrUtils, Math, PNGComn, zstream,
  // LazUtils
  LConvEncoding,
  // LCL
  Forms, Controls, Graphics, Dialogs, StdCtrls, ExtCtrls, ComCtrls, ShellCtrls;

type
  TChunk_CHRM = packed record
    WhitePointX: LongWord;
    WhitePointY: LongWord;
    RedX: LongWord;
    RedY: LongWord;
    GreenX: LongWord;
    GreenY: LongWord;
    BlueX: LongWord;
    BlueY: LongWord;
  end;
  PChunk_CHRM = ^TChunk_CHRM;

  TChunk_IHDR = packed record
    Width: LongWord;
    Height: LongWord;
    BitDepth: Byte;
    ColorType: Byte;
    CompressionMethod: Byte;
    FilterMethod: Byte;
    InterlaceMethod: Byte;
  end;
  PChunk_IHDR = ^TChunk_IHDR;

  TChunk_PHYS = packed record
    PixelsPerUnitX: LongWord;
    PixelsPerUnitY: LongWord;
    UnitSpecifier: Byte;
  end;
  PChunk_PHYS = ^TChunk_PHYS;

  TChunk_TIME = packed record
    Year: Word;   // complete; for example, 1995, not 95)
    Month: Byte;  // 1-12
    Day: Byte;    // 1-31
    Hour: Byte;   // 0-23
    Minute: Byte; // 0-59
    Second: Byte; // 0-60 -- yes, 60, for leap seconds; not 61, a common error
  end;
  PChunk_TIME = ^TChunk_TIME;

  TpngChunk = class
    Position: Int64;
    CType: string[4];
    Data: TBytes;
    CRC: LongWord;
    function DataAsString: String;
  end;

  TpngChunkList = class(TFPObjectList)
  private
    function GetItem(AIndex: Integer): TpngChunk;
    procedure SetItem(AIndex: Integer; AValue: TpngChunk);
  public
    property Items[AIndex: Integer]: TpngChunk read GetItem write SetItem; default;
  end;


  { TMainForm }

  TMainForm = class(TForm)
    Image1: TImage;
    Image2: TImage;
    lbChunks: TListBox;
    ChunkMemo: TMemo;
    PageControl1: TPageControl;
    Panel1: TPanel;
    Panel2: TPanel;
    Panel3: TPanel;
    ScrollBox1: TScrollBox;
    ShellListView: TShellListView;
    ShellTreeView: TShellTreeView;
    MainSplitter: TSplitter;
    TV_LV_Splitter: TSplitter;
    TabSheet1: TTabSheet;
    TabSheet2: TTabSheet;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure lbChunksClick(Sender: TObject);
    procedure ShellListViewSelectItem(Sender: TObject; Item: TListItem;
      Selected: Boolean);
  private
    FChunks: TpngChunkList;
    procedure ChunksToListbox;
    procedure CollectChunks(AStream: TStream);
    function GetChunk(AIndex: Integer): TpngChunk;
    function GetColorType: Integer;
    function GetCurrentChunk: TpngChunk;
    procedure LoadImage(AStream: TStream);

    procedure ShowChunkHeader(AChunk: TpngChunk; const AName: String);
    procedure Show_bKGD(AChunk: TpngChunk);
    procedure Show_cHRM(AChunk: TpngChunk);
    procedure Show_gAMA(AChunk: TpngChunk);
    procedure Show_hIST(AChunk: TpngChunk);
    procedure Show_IDAT(AChunk: TpngChunk);
    procedure Show_IEND(AChunk: TpngChunk);
    procedure Show_IHDR(AChunk: TpngChunk);
    procedure Show_iTXt(AChunk: TpngChunk);
    procedure Show_pHYs(AChunk: TpngChunk);
    procedure Show_PLTE(AChunk: TpngChunk);
    procedure Show_sRGB(AChunk: TpngChunk);
    procedure Show_sBIT(AChunk: TpngChunk);
    procedure Show_sPLT(AChunk: TpngChunk);
    procedure Show_tEXt(AChunk: TpngChunk);
    procedure Show_tIME(AChunk: TpngChunk);
    procedure Show_tRNS(AChunk: TpngChunk);
    procedure Show_Unknown(AChunk: TpngChunk);
    procedure Show_zTXt(AChunk: TpngChunk);

  public
    procedure LoadFile(const AFileName: String);

  end;

var
  MainForm: TMainForm;

implementation

{$R *.lfm}

const
  APP_TITLE = 'pngExplorer';
  DIVISOR = 100000;
  INCH = 0.0254;  // 1" in meters


function Deflate(CompressedText: AnsiString): AnsiString;
var
  InStream: TStringStream;
  OutStream: TMemoryStream;
  DecompressionStream: TDecompressionStream = nil;
begin
  Result := '';
  InStream := TStringStream.Create(CompressedText);
  OutStream := TMemoryStream.Create();
  try
    InStream.Position := 0;
    DecompressionStream := TDecompressionStream.Create(InStream);
    OutStream.CopyFrom(DecompressionStream, 0);
    OutStream.Position := 0;
    SetLength(Result, OutStream.Size);
    OutStream.Read(Result[1], OutStream.Size);
  finally
    DecompressionStream.Free;
    OutStream.Free;
  end;
end;


{ TpngChunk }

function TpngChunk.DataAsString: String;
begin
  if Data <> nil then
  begin
    SetLength(Result, Length(Data));
    Move(Data[0], Result[1], Length(Data));
  end else
    Result := '';
end;


{ TpngChunkList }

function TpngChunkList.GetItem(AIndex: Integer): TpngChunk;
begin
  Result := TpngChunk(inherited Items[AIndex]);
end;

procedure TpngChunkList.SetItem(AIndex: Integer; AValue: TpngChunk);
begin
  inherited Items[AIndex] := AValue;
end;


{ TMainForm }

procedure TMainForm.ChunksToListbox;
var
  i: Integer;
begin
  lbChunks.Items.BeginUpdate;
  try
    lbChunks.Items.Clear;
    for i := 0 to FChunks.Count-1 do
      lbChunks.Items.Add(FChunks[i].CType);
  finally
    lbChunks.Items.EndUpdate;
  end;
end;

procedure TMainForm.CollectChunks(AStream: TStream);
var
  chunk: TpngChunk;
  hdr: TChunkHeader;
  pngSig: Array[0..7] of Byte = (0, 0, 0, 0, 0, 0, 0, 0);
  P: Int64;
begin
  hdr := Default(TChunkHeader);
  FChunks.Clear;
  AStream.Read(pngSig, SizeOf(pngSig));
  // It already has been verified that the signature is correct --> just continue...
  while AStream.Position < AStream.Size do
  begin
    P := AStream.Position;
    AStream.Read(hdr, SizeOf(hdr));
    chunk := TpngChunk.Create;
    chunk.Position := P;
    chunk.CType := String(hdr.CType);
    if hdr.CLength > 0 then
    begin
      SetLength(chunk.Data, BEToN(hdr.CLength));
      AStream.Read(chunk.Data[0], Length(chunk.Data));
    end else
      chunk.Data := nil;
    AStream.Read(chunk.CRC, SizeOf(chunk.CRC));
    chunk.CRC := BEToN(chunk.CRC);
    FChunks.Add(chunk);
  end;
  ChunksToListbox;
  AStream.Position := 0;
end;

procedure TMainForm.FormCreate(Sender: TObject);
var
  fn, dir: String;
begin
  FChunks := TpngChunkList.Create;

  Caption := APP_TITLE;
  if ParamCount > 0 then
  begin
    if FileExists(ParamStr(1)) then
    begin
      fn := ExtractFileName(ParamStr(1));
      dir := ExtractFilePath(ParamStr(1));
      ShellTreeView.Path := dir;
      ShellListView.Selected := ShellListView.FindCaption(0, fn, true, true, true);
    end else
      ShellTreeView.Path := ParamStr(1);
  end;
end;

procedure TMainForm.FormDestroy(Sender: TObject);
begin
  FChunks.Free;
end;

function TMainForm.GetChunk(AIndex: Integer): TpngChunk;
begin
  if (AIndex >= 0) and (AIndex < FChunks.Count) then
    Result := FChunks[AIndex]
  else
    Result := nil;
end;

function TMainForm.GetColorType: Integer;
var
  chunk: TpngChunk;
begin
  chunk := GetChunk(0);
  if chunk <> nil then
    Result := PChunk_IHDR(chunk.Data)^.ColorType
  else
    Result := -1;
end;

function TMainForm.GetCurrentChunk: TpngChunk;
begin
  if lbChunks.ItemIndex > -1 then
    Result := FChunks[lbChunks.ItemIndex]
  else
    Result := nil;
end;

procedure TMainForm.lbChunksClick(Sender: TObject);
var
  chunk: TpngChunk;
begin
  if lbChunks.ItemIndex = -1 then
    exit;

  chunk := GetCurrentChunk;
  ChunkMemo.Lines.Clear;
  if chunk <> nil then
    case chunk.CType of
      'bKGD' : Show_bKGD(chunk);
      'cHRM' : Show_cHRM(chunk);
      'gAMA' : Show_gAMA(chunk);
      'hIST' : Show_hIST(chunk);
      'IDAT' : Show_IDAT(chunk);
      'IHDR' : Show_IHDR(chunk);
      'IEND' : Show_IEND(chunk);
      'iTXt' : Show_iTXt(chunk);
      'PLTE' : Show_PLTE(chunk);
      'pHYs' : Show_pHYs(chunk);
      'sBIT' : Show_sBIT(chunk);
      'sPLT' : Show_sPLT(chunk);
      'sRGB' : Show_sRGB(chunk);
      'tEXt' : Show_tEXt(chunk);
      'tIME' : Show_tIME(chunk);
      'tRNS' : Show_tRNS(chunk);
      'zTXt' : Show_zTXt(chunk);
      else     Show_Unknown(chunk);
    end;
end;

procedure TMainForm.LoadFile(const AFileName: String);
var
  stream: TStream;
begin
  if not FileExists(AFileName) then
  begin
    Image1.Picture.Clear;
    Caption := APP_TITLE;
    exit;
  end;

  if TPicture.FindGraphicClassWithFileExt(ExtractFileExt(AFileName), false) <> TPortableNetworkGraphic then
  begin
    MessageDlg(Format('File "%s" is not a valid png file.', [AFileName]), mtError, [mbOK], 0);
    exit;
  end;

  Caption := APP_TITLE + ' - ' + ExpandFileName(AFileName);

  stream := TFileStream.Create(AFileName, fmOpenRead);
  try
    LoadImage(stream);
    CollectChunks(stream);
  finally
    stream.Free;
  end;
end;

procedure TMainForm.LoadImage(AStream: TStream);
begin
  Image1.Picture.LoadFromStream(AStream);
  AStream.Position := 0;
  Image2.Picture.LoadFromStream(AStream);
  AStream.Position := 0;
end;

procedure TMainForm.ShellListViewSelectItem(Sender: TObject; Item: TListItem;
  Selected: Boolean);
begin
  if Selected then
  begin
    LoadFile(ShellListView.GetPathFromItem(Item));
    ChunkMemo.Lines.Clear;
  end;
end;

procedure TMainForm.Show_bKGD(AChunk: TpngChunk);
var
  hdrChunk: TpngChunk;
  hdr: PChunk_IHDR;
begin
  if Length(AChunk.Data) = 0 then
    exit;

  ChunkMemo.Lines.BeginUpdate;
  try
    hdrChunk := GetChunk(0);
    hdr := PChunk_IHDR(@hdrChunk.Data[0]);
    ShowChunkHeader(AChunk, 'Background color');
    case hdr^.ColorType of
      0, 4:   // gray scale without/with alpha
        begin
          ChunkMemo.Lines.Add(' Gray level: %d', [BEToN(PWord(@AChunk.Data[0])^)]);
        end;
      2, 6:  // truecolor without/with alpha
        begin
          ChunkMemo.Lines.Add('   Red level: %d', [BEToN(PWord(@AChunk.Data[0])^)]);
          ChunkMemo.Lines.Add(' Green level: %d', [BEToN(PWord(@AChunk.Data[2])^)]);
          ChunkMemo.Lines.Add('  Blue level: %d', [BEToN(PWord(@AChunk.Data[4])^)]);
        end;
      3:     // indexed color
        begin
          ChunkMemo.Lines.Add(' Palette index: %d', [AChunk.Data[0]]);
        end;
    end;
  finally
    ChunkMemo.Lines.EndUpdate;
  end;
end;

procedure TMainForm.ShowChunkHeader(AChunk: TpngChunk; const AName: String);
begin
  if AName <> '' then
    ChunkMemo.Lines.Add(AName);
  ChunkMemo.Lines.Add('%s chunk (Position: %d; Data length: %d; CRC: %u)', [
    AChunk.CType, AChunk.Position, Length(AChunk.Data), AChunk.CRC
  ]);
  ChunkMemo.Lines.Add('------------------------------------------------------------');
end;

procedure TMainForm.Show_cHRM(AChunk: TpngChunk);
var
  chrm: PChunk_CHRM;
  fs: TFormatSettings;
begin
  if (Length(AChunk.Data) > 0) then
  begin
    chrm := PChunk_CHRM(@AChunk.Data[0]);
    ChunkMemo.Lines.BeginUpdate;
    try
      ShowChunkHeader(AChunk, 'Primary chromaticities');
      fs := DefaultFormatSettings;
      fs.DecimalSeparator := '.';
      ChunkMemo.Lines.Add(Format(' White Point x: %.4f', [BEToN(chrm^.WhitePointX)/DIVISOR], fs));
      ChunkMemo.Lines.Add(Format(' White Point y: %.4f', [BEToN(chrm^.WhitePointY)/DIVISOR], fs));
      ChunkMemo.Lines.Add(Format('         Red x: %.4f', [BEToN(chrm^.RedX)/DIVISOR], fs));
      ChunkMemo.Lines.Add(Format('         Red y: %.4f', [BEToN(chrm^.RedY)/DIVISOR], fs));
      ChunkMemo.Lines.Add(Format('       Green x: %.4f', [BEToN(chrm^.GreenX)/DIVISOR], fs));
      ChunkMemo.Lines.Add(Format('       Green y: %.4f', [BEToN(chrm^.GreenY)/DIVISOR], fs));
      ChunkMemo.Lines.Add(Format('        Blue x: %.4f', [BEToN(chrm^.BlueX)/DIVISOR], fs));
      ChunkMemo.Lines.Add(Format('        Blue y: %.4f', [BEToN(chrm^.BlueY)/DIVISOR], fs));
    finally
      ChunkMemo.Lines.EndUpdate;
    end;
  end;
end;

procedure TMainForm.Show_gAMA(AChunk: TpngChunk);
var
  gamma: DWord;
  fs: TFormatSettings;
begin
  if Length(AChunk.Data) > 0 then
  begin
    gamma := BEToN(PLongWord(@AChunk.Data[0])^);
    fs := DefaultFormatSettings;
    fs.DecimalSeparator := '.';
    ShowChunkHeader(AChunk, 'Image gamma');
    ChunkMemo.Lines.Add(Format(' Gamma: %.4f = 1/%.1f', [gamma/DIVISOR, 1.0/(gamma/DIVISOR)], fs));
  end;
end;

procedure TMainForm.Show_hIST(AChunk: TpngChunk);
begin
  ChunkMemo.Lines.BeginUpdate;
  try
    ShowchunkHeader(AChunk, 'Palette histogram');
    ChunkMemo.Lines.Add('(to do)');
  finally
    ChunkMemo.Lines.EndUpdate;
  end;
end;

procedure TMainForm.Show_IDAT(AChunk: TpngChunk);
begin
  ChunkMemo.Lines.BeginUpdate;
  try
    ShowChunkHeader(AChunk, 'Image data');
    ChunkMemo.Lines.Add('(to do)');
  finally
    ChunkMemo.Lines.EndUpdate;
  end;
end;

procedure TMainForm.Show_IEND(AChunk: TpngChunk);
begin
  ChunkMemo.Lines.BeginUpdate;
  try
    ShowChunkHeader(AChunk, 'Image trailer');
    ChunkMemo.Lines.Add('The IEND chunk contains no data.');
  finally
    ChunkMemo.Lines.EndUpdate;
  end;
end;

procedure TMainForm.Show_IHDR(AChunk: TpngChunk);
var
  ihdr: PChunk_IHDR;
  sampleDepth: String = '';
  colorType: String = '';
  comprMethod: String = '';
  filterMethod: String = '';
  interlaceMethod: String = '';
begin
  if (Length(AChunk.Data) > 0) then
  begin
    ihdr := PChunk_IHDR(@AChunk.Data[0]);
    ChunkMemo.Lines.BeginUpdate;
    try
      ShowChunkHeader(AChunk, 'Image header');
      if ihdr^.BitDepth = 3 then
        sampleDepth := '(8 bits per sample)'
      else
        sampleDepth := '(' + IntToStr(ihdr^.BitDepth) + ' bits per sample)';

      case ihdr^.ColorType of
        0: colorType := '(gray scale)';
        2: colorType := '(true color)';
        3: colorType := '(indexed color)';
        4: colorType := '(gray scale with alpha channel)';
        6: colorType := '(true color with alpha channel)';
      end;
      if (ihdr^.CompressionMethod = 0) then
        comprMethod := '(deflate/inflate compression)';
      if (ihdr^.FilterMethod = 0) then
        filterMethod := '(adaptive filtering)';
      case ihdr^.InterlaceMethod of
        0: interlaceMethod := '(no interlace)';
        1: interlaceMethod := '(Adam 7 interlace)';
      end;

      ChunkMemo.Lines.Add(Format('              Width: %d', [BEToN(ihdr^.Width)]));
      ChunkMemo.Lines.Add(Format('             Height: %d', [BEToN(ihdr^.Height)]));
      ChunkMemo.Lines.Add(Format('          Bit depth: %d %s', [ihdr^.BitDepth, sampleDepth]));
      ChunkMemo.Lines.Add(Format('         Color type: %d %s', [ihdr^.ColorType, colorType]));
      ChunkMemo.Lines.Add(Format(' Compression method: %d %s', [ihdr^.CompressionMethod, comprMethod]));
      ChunkMemo.Lines.Add(Format('      Filter method: %d %s', [ihdr^.FilterMethod, filterMethod]));
      ChunkMemo.Lines.Add(Format('   Interlace method: %d %s', [ihdr^.InterlaceMethod, interlaceMethod]));
      ChunkMemo.Lines.Add('');

      case ihdr^.ColorType of
        0: if ihdr^.BitDepth in [1, 2, 3, 8, 16] then
             ChunkMemo.Lines.Add('Each pixel is a grayscale sample.');
        2: if ihdr^.BitDepth in [8, 16] then
             ChunkMemo.Lines.Add('Each pixel is an R,G,B triple.');
        3: if ihdr^.BitDepth in [1, 2, 4, 8] then
             ChunkMemo.Lines.Add('Each pixel is a palette index; a PLTE chunk must appear.');
        4: if ihdr^.Bitdepth in [8, 16] then
             ChunkMemo.Lines.Add('Each pixel is a grayscale sample, followed by an alpha sample.');
        6: if ihdr^.BitDepth in [8, 16] then
             ChunkMemo.Lines.Add('Each pixel is an R,G,B triple, followed by an alpha sample.');
      end;
    finally
      ChunkMemo.Lines.EndUpdate;
    end;
  end;
end;

procedure TMainForm.Show_iTXt(AChunk: TpngChunk);
var
  keyword: AnsiString;
  compressionFlag: Byte;
  compressionMethod: Byte;
  languageTag: AnsiString;
  compressed: AnsiString;
  uncompressed: AnsiString;
  translatedKeyword: AnsiString;
  compressionFlagStr: String;
  compressionMethodStr: String;
  p, len: Integer;

begin
  if Length(AChunk.Data) = 0 then
    exit;

  keyword := PChar(@AChunk.Data[0]);
  compressionFlag := AChunk.Data[Length(keyword)+1];
  case compressionFlag of
    0: compressionFlagStr := 'uncompressed';
    1: compressionFlagStr := 'compressed';
  end;
  compressionMethod := AChunk.Data[Length(keyword)+2];
  compressionMethodStr := 'zlib deflate';
  languageTag := PChar(@AChunk.Data[Length(keyword)+3]);
  translatedKeyword := PChar(@AChunk.Data[Length(keyword) + Length(languageTag) + 4]);
  p := Length(keyword) + Length(LanguageTag) + Length(translatedKeyword) + 3 + 2;
  len := Length(AChunk.Data) - p;
  SetLength(compressed, len);
  Move(AChunk.Data[p], compressed[1], len);
  if compressionFlag = 0 then
    uncompressed := compressed
  else
    uncompressed := Deflate(compressed);

  ChunkMemo.Lines.BeginUpdate;
  try
    ShowChunkHeader(AChunk, 'International textual data');
    ChunkMemo.Lines.Add('            Keyword: %s', [keyword]);
    ChunkMemo.Lines.Add('   Compression flag: %d (%s)', [compressionFlag, compressionFlagStr]);
    ChunkMemo.Lines.Add(' Compression method: %d (%s)', [compressionMethod, compressionMethodStr]);
    ChunkMemo.Lines.Add('       Language tag: %s', [languageTag]);
    ChunkMemo.Lines.Add(' Translated keyword: %s', [translatedKeyword]);
    ChunkMemo.Lines.Add('    Compressed text: (not shown)');
    ChunkMemo.Lines.Add('');
    ChunkMemo.Lines.Add('Here follows the uncompressed text:');
    ChunkMemo.Lines.Add('');
    ChunkMemo.Lines.Add(uncompressed);
  finally
    ChunkMemo.Lines.EndUpdate;
  end;
end;

procedure TMainForm.Show_PLTE(AChunk: TpngChunk);
var
  i, pal, numEntries: Integer;
  s: String;
  w: Integer;
begin
  if Length(AChunk.Data) = 0 then
    exit;

  numEntries := Length(AChunk.Data) div 3;
  ChunkMemo.Lines.BeginUpdate;
  try
    ShowChunkHeader(AChunk, 'Palette');
    if numEntries < 10 then w := 1 else if numEntries < 100 then w := 2 else w := 3;
    i := 0;
    pal := 0;
    while i < numEntries do
    begin
      s := Format('Palette index %*.d', [w, pal]);
      with AChunk do
        ChunkMemo.Lines.Add(' %s: R %.3d, G %.3d, B %.3d', [s, Data[i], Data[i+1], Data[i+2]]);
      inc(i, 3);
      inc(pal);
    end;
  finally
    ChunkMemo.Lines.EndUpdate;
  end;
end;

procedure TMainForm.Show_pHYs(AChunk: TpngChunk);
var
  phys: PChunk_PHYS;
  unitStr: String;
  xPPI: String = '';
  yPPI: String = '';
begin
  if (Length(AChunk.Data) > 0) then
  begin
    phys := PChunk_PHYS(@AChunk.Data[0]);
    case phys^.UnitSpecifier of
      0: unitStr := 'unknown (aspect ratio only)';
      1: begin
           unitStr := 'meters';
           xPPI := Format(' (%.0f ppi)', [BEToN(phys^.PixelsPerUnitX) * INCH]);
           yPPI := Format(' (%.0f ppi)', [BEToN(phys^.PixelsPerUnitY) * INCH]);
         end;
    end;
    ChunkMemo.Lines.BeginUpdate;
    try
      ShowChunkHeader(AChunk, 'Physical pixel dimensions');
      ChunkMemo.Lines.Add(' Pixels per unit (X): %d %s', [BEToN(phys^.PixelsPerUnitX), xPPI]);
      ChunkMemo.Lines.Add(' Pixels per unit (Y): %d %s', [BEToN(phys^.PixelsPerUnitY), yPPI]);
      ChunkMemo.Lines.Add('      Unit specifier: %s', [unitStr]);
    finally
      ChunkMemo.Lines.EndUpdate;
    end;
  end;
end;

procedure TMainForm.Show_sBIT(AChunk: TpngChunk);
var
  hdrChunk: TpngChunk;
  hdr: PChunk_IHDR;
begin
  if Length(AChunk.Data) = 0 then
    exit;

  ChunkMemo.Lines.BeginUpdate;
  try
    hdrChunk := GetChunk(0);
    hdr := PChunk_IHDR(@hdrChunk.Data[0]);
    ShowChunkHeader(AChunk, 'Significant bits');
    case hdr^.ColorType of
      0: begin  // gray scale
           ChunkMemo.Lines.Add(' Significant bits: %d', [AChunk.Data[0]]);
         end;
      2: begin  // true color
           ChunkMemo.Lines.Add('   Significant red bits: %d', [AChunk.Data[0]]);
           ChunkMemo.Lines.Add(' Significant green bits: %d', [AChunk.Data[1]]);
           ChunkMemo.Lines.Add('  Significant blue bits: %d', [AChunk.Data[2]]);
         end;
      3: begin  // indexed color
           ChunkMemo.Lines.Add('   Significant red palette bits: %d', [AChunk.Data[0]]);
           ChunkMemo.Lines.Add(' Significant green palette bits: %d', [AChunk.Data[1]]);
           ChunkMemo.Lines.Add('  Significant blue palette bits: %d', [AChunk.Data[2]]);
         end;
      4: begin  // gray scale with alpha
           ChunkMemo.Lines.Add(' Significant bits: %d', [AChunk.Data[0]]);
           ChunkMemo.Lines.Add(' Significant alpha bits: %d', [AChunk.Data[1]]);
         end;
      6: begin  // true color with alpha
           ChunkMemo.Lines.Add('   Significant red bits: %d', [AChunk.Data[0]]);
           ChunkMemo.Lines.Add(' Significant green bits: %d', [AChunk.Data[1]]);
           ChunkMemo.Lines.Add('  Significant blue bits: %d', [AChunk.Data[2]]);
           ChunkMemo.Lines.Add(' Significant alpha bits: %d', [AChunk.Data[3]]);
         end;
    end;
  finally
    ChunkMemo.Lines.EndUpdate;
  end;
end;

procedure TMainForm.Show_sPLT(AChunk: TpngChunk);
var
  paletteName: String;
  sampleDepth: Byte;
  i, p, numEntries, remainder: Integer;
  itemSize: Integer;
  wi, w: Integer;
  r,g,b,a,f: Integer;
begin
  if Length(AChunk.Data) = 0 then
    exit;

  paletteName := PChar(@AChunk.Data[0]);
  sampleDepth := AChunk.Data[Length(paletteName) + 1];
  p := Length(paletteName) + 1 + 1;
  case sampleDepth of
    8: begin itemSize := 6; w := 3; end;
   16: begin itemSize := 10; w := 5; end;
    else
      exit;  // error in file
   end;
  DivMod((Length(AChunk.Data) - p), itemSize, numEntries, remainder);
  if remainder <> 0 then
    exit;
  if numEntries < 10 then wi := 1 else if numentries < 100 then wi := 2 else wi := 3;

  ChunkMemo.Lines.BeginUpdate;
  try
    ShowChunkHeader(AChunk, 'Suggested palette');
    ChunkMemo.Lines.Add(' %*sPalette name: %s', [wi, ' ', paletteName]);
    ChunkMemo.Lines.Add(' %*sSample depth: %d', [wi, ' ', sampleDepth]);
    i := 0;
    p := 0;
    while i < numEntries do
    begin
      case sampleDepth of
        8: begin
             r := AChunk.Data[i];
             g := AChunk.Data[i+1];
             b := AChunk.Data[i+2];
             a := AChunk.Data[i+3];
             f := PWord(@AChunk.Data[i+4])^;
             inc(i, 6);
           end;
       16: begin
             r := PWord(@AChunk.Data[i])^;
             g := PWord(@AChunk.Data[i+2])^;
             b := PWord(@AChunk.Data[i+4])^;
             a := PWord(@AChunk.Data[i+6])^;
             f := PWord(@AChunk.Data[i+8])^;
             inc(i, 10);
           end;
      end;
      ChunkMemo.Lines.Add('        Index %*.d: R%*.3d, G%*.3d, B%*.3d, A%*.3d, Freq%d', [
        wi, p, w, r, w, g, w, b, w, a, f]);
      inc(p);
    end;
  finally
    ChunkMemo.Lines.EndUpdate;
  end;
end;


procedure TMainForm.Show_sRGB(AChunk: TpngChunk);
const
  RENDERING_INTENT: array[0..3] of String = (
    'Perceptual', 'Relative colorimetric', 'Saturation', 'Absolute colorimetric'
  );
begin
  if Length(AChunk.Data) > 0 then
  begin
    ChunkMemo.Lines.BeginUpdate;
    try
      ShowChunkHeader(AChunk, 'Standard RGB color space');
      ChunkMemo.Lines.Add(' Rendering intent: %d (%s)', [
        AChunk.Data[0], RENDERING_INTENT[AChunk.Data[0]]
      ]);
    finally
      ChunkMemo.Lines.EndUpdate;
    end;
  end;
end;

procedure TMainForm.Show_tEXt(AChunk: TpngChunk);
var
  sa: TStringArray;
begin
  if (Length(AChunk.Data) > 0) then
  begin
    ChunkMemo.Lines.BeginUpdate;
    try
      ShowChunkHeader(AChunk, 'Textual data');
      sa := AChunk.DataAsString.Split(#0);
      ChunkMemo.Lines.Add('    Keyword: ' + sa[0]);
      ChunkMemo.Lines.Add(' Text value: ' + ISO_8859_1ToUTF8(sa[1]));
    finally
      ChunkMemo.Lines.EndUpdate;
    end;
  end;
end;

procedure TMainForm.Show_tIME(AChunk: TpngChunk);
var
  timeCh: PChunk_TIME;
begin
  if Length(AChunk.Data) > 0 then
  begin
    timeCh := PChunk_TIME(@AChunk.Data[0]);
    ChunkMemo.Lines.BeginUpdate;
    try
      ShowChunkHeader(AChunk, 'Image last modification time');
      ChunkMemo.Lines.Add('   Year: %d', [BEToN(timeCh^.Year)]);
      ChunkMemo.Lines.Add('  Month: %d', [timeCh^.Month]);
      ChunkMemo.Lines.Add('    Day: %d', [timeCh^.Day]);
      ChunkMemo.Lines.Add('   Hour: %d', [timeCh^.Hour]);
      ChunkMemo.Lines.Add(' Minute: %d', [timeCh^.Minute]);
      ChunkMemo.Lines.Add(' Second: %d', [timeCh^.Second]);
    finally
      ChunkMemo.Lines.EndUpdate;
    end;
  end;
end;

procedure TMainForm.Show_tRNS(AChunk: TpngChunk);
var
  i, pal, numEntries: Integer;
  s: String;
  w: Integer;
  value: Integer;
begin
  if Length(AChunk.Data) = 0 then
    exit;

  ChunkMemo.Lines.BeginUpdate;
  try
    ShowChunkHeader(AChunk, 'Transparency');

    case GetColorType of
      0: begin     // gray scale
           ChunkMemo.Lines.Add(' Gray level: %d', [PWord(@AChunk.Data[0])^]);
         end;
      2: begin     // true color
           ChunkMemo.Lines.Add('   Red level: %d', [PWord(@AChunk.Data[0])^]);
           ChunkMemo.Lines.Add(' Green level: %d', [PWord(@AChunk.Data[2])^]);
           ChunkMemo.Lines.Add('  Blue level: %d', [PWord(@AChunk.Data[4])^]);
         end;
      3: begin    // indexed color
           numEntries := Length(AChunk.Data);
           if numEntries < 10 then w := 1 else if numEntries < 100 then w := 2 else w := 3;
           for i := 0 to numEntries-1 do
             ChunkMemo.Lines.Add(' Alpha for palette index %*.d: %d', [w, i, AChunk.Data[i]]);
         end;
    end;
  finally
    ChunkMemo.Lines.EndUpdate;
  end;
end;

procedure TMainForm.Show_Unknown(AChunk: TpngChunk);
begin
  ShowChunkHeader(AChunk, '');
  ChunkMemo.Lines.Add('unknown data');
end;

procedure TMainForm.Show_zTXt(AChunk: TpngChunk);
var
  keyword: String;
  compressionMethod: Byte;
  compressionMethodStr: String;
  compressed: AnsiString = '';
  uncompressed: AnsiString;
  p, len: Integer;
begin
  if Length(AChunk.Data) = 0 then
    exit;

  keyword := PChar(@AChunk.Data[0]);
  compressionMethod := AChunk.Data[Length(keyword)+1];
  compressionMethodStr := 'zlib deflate';
  p := Length(keyword) + 1 + 1;
  len := Length(AChunk.Data) - p;
  SetLength(compressed, len);
  Move(AChunk.Data[p], compressed[1], len);
  uncompressed := Deflate(compressed);

  ChunkMemo.Lines.BeginUpdate;
  try
    ShowChunkHeader(AChunk, 'Compressed textual data');
    ChunkMemo.Lines.Add('            Keyword: %s', [keyword]);
    ChunkMemo.Lines.Add(' Compression method: %d (%s)', [compressionMethod, compressionMethodStr]);
    ChunkMemo.Lines.Add('    Compressed text: %s', ['(not shown)' {compressed}]);
    ChunkMemo.Lines.Add('  Uncompressed text: %s', [uncompressed]);
  finally
    ChunkMemo.Lines.EndUpdate;
  end;
end;

end.

