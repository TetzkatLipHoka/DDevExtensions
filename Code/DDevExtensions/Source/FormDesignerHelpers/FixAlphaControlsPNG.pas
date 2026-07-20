unit FixAlphaControlsPNG;

{$I ..\DelphiExtension.inc}
{.$DEFINE PNGGraphicBMP}

interface

{$IFDEF INCLUDE_ACPNGFIX}

uses
  Classes, Graphics, pngimage;

type
  {$IFDEF PNGGraphicBMP} // Converter for AlphaControls (acPNG)
  TPNGGraphic = class( TBitmap ) 
  {$ELSE}
  TPNGGraphic = class( TPngImage )
  {$ENDIF}
  protected
    procedure WriteData(Stream: TStream); override;
  public
    procedure LoadFromStream(Stream: TStream); override;
  end;

procedure SetFixAlphaControlsPNGActive(Active: Boolean);

{$ENDIF}

implementation

{$IFDEF INCLUDE_ACPNGFIX}
uses
  pnglang;
{$ENDIF}

{$IFDEF INCLUDE_ACPNGFIX}

{
  acPNG (AlphaControls) DFM stream layout that LoadFromStream below parses
  -----------------------------------------------------------------------
  A TPicture writes its graphic as:  [len:Byte]['<GraphicClassName>'][graphic data]
  (TPicture.WriteData: Write(CName, Length(CName)+1), then Graphic.WriteData).

  AlphaControls' graphic class is ALSO named 'TPNGGraphic', and it does NOT
  store real PNG bytes - it stores a Windows BMP under that class name, with a
  few of its own header bytes in between:

    offset 0            : len byte      = 11  (Length('TPNGGraphic'))
    offset 1 .. 11      : 'TPNGGraphic' (the class name; == our ClassName)
    offset 12 .. ~21    : acPNG's own small header/padding (variable)
    offset (first 'BM') : 'B''M' + standard BMP (BITMAPFILEHEADER ...)

  So we: read 11 bytes at position 1, confirm they equal our ClassName; then
  scan the next ~10 bytes one at a time for the 'BM' bitmap signature; rewind
  to the 'B' and load the embedded BMP. Assigning that BMP to the TPngImage
  turns acPNG's fake PNG into a real image; WriteData then re-streams it as a
  genuine 'TPngImage' PNG, so the picture becomes portable.

  NB this depends on acPNG's exact byte layout - if AlphaControls ever changes
  its streaming, the 'BM' scan below stops matching and the load raises
  EPNGInvalidFileHeader (safe failure, no corruption).
}

{$IFDEF PNGGraphicBMP}
procedure TPNGGraphic.LoadFromStream(Stream: TStream);
const
  BmpHeader: Array[0..1] of AnsiChar = ('B', 'M' ); //, '6');
var
  Header    : Array[0..10] of AnsiChar;
  HeaderBMP : Array[0..1] of AnsiChar absolute Header;
  found     : Boolean;
  i         : Integer;
begin
  {Reads the header}
  Stream.Position := 1;
  Stream.Read(Header[0], Length(Header));

  {Test if the header matches}
  if String( Header ) = ClassName then // PngHeaderAC then
    begin
    found := False;
    for i := 0 to 10 do
      begin
      Stream.Read(HeaderBMP[0], Length(HeaderBMP));
      Stream.Position := Stream.Position-1;
      if HeaderBMP = BmpHeader then 
        begin
        Stream.Position := Stream.Position-1; 
        found := True;
        break;
        end;
      end;
    if found then 
      begin
      inherited LoadFromStream( Stream );
      Exit;
      end;
    end;

  //RaiseError(EPNGInvalidFileHeader, EPNGInvalidFileHeaderText);
  raise EPNGInvalidFileHeader.Create(EPNGInvalidFileHeaderText);
end;

procedure TPNGGraphic.WriteData(Stream: TStream);
var
  S : AnsiString;
  i : Byte;
begin
  Stream.Position := 0;
  S := AnsiString( TBitmap.ClassName );
  i := Length( S );

  Stream.Write( i, SizeOf( i ) );
  Stream.Write( S[ 1 ], i );

  inherited;
end;
{$ELSE}

{Loads the image from a stream of data}
procedure TPNGGraphic.LoadFromStream(Stream: TStream);
const
  BmpHeader: Array[0..1] of AnsiChar = ('B', 'M' ); //, '6');
var
  Header    : Array[0..10] of AnsiChar;
  HeaderBMP : Array[0..1] of AnsiChar absolute Header;
  bmp       : TBitmap;
  found     : Boolean;
  i         : Integer;
begin
  {Reads the header}
  Stream.Position := 1;
  Stream.Read(Header[0], Length(Header));

  {Test if the header matches}
  if String( Header ) = ClassName then // PngHeaderAC then
    begin
    found := False;
    for i := 0 to 10 do
      begin
      Stream.Read(HeaderBMP[0], Length(HeaderBMP));
      Stream.Position := Stream.Position-1;
      if HeaderBMP = BmpHeader then 
        begin
        Stream.Position := Stream.Position-1; 
        found := True;
        break;
        end;
      end;
    if found then 
      begin
      bmp := TBitmap.Create;
      bmp.LoadFromStream( Stream );
      Assign( bmp );
      bmp.free;

      Changed(Self);
      Exit;
      end;
    end;

  RaiseError(EPNGInvalidFileHeader, EPNGInvalidFileHeaderText);
end;

procedure TPNGGraphic.WriteData(Stream: TStream);
var
  S : AnsiString;
  i : Byte;
begin
  Stream.Position := 0;
  S := AnsiString( TPNGImage.ClassName );
  i := Length( S );

  Stream.Write( i, SizeOf( i ) );
  Stream.Write( S[ 1 ], i );

  SaveToStream(Stream);
end;
{$ENDIF PNGGraphic}

var
  IsActive: Boolean;

procedure SetFixAlphaControlsPNGActive(Active: Boolean);
begin
  if Active <> IsActive then
  begin
    IsActive := Active;
    if Active then
    begin
      {$IFNDEF COMPILER12_UP}
      // pre-2009 IDEs have no native pngimage: also provide the statically
      // linked TPngImage (repo copy in Shared\PNGDelphi, built with
      // -DDDEV_PNG_NOINIT so it does NOT self-register), so 'png' files load
      // properly and the DFMs written by our converter (class name
      // 'TPngImage') stream back in
      TPicture.RegisterFileFormat('png', 'Portable Network Graphics', TPngImage);
      {$ENDIF}
      TPicture.RegisterFileFormat('', 'Portable network graphics (AlphaControls)', TPNGGraphic);
    end
    else
    begin
      TPicture.UnregisterGraphicClass(TPNGGraphic);
      {$IFNDEF COMPILER12_UP}
      TPicture.UnregisterGraphicClass(TPngImage);
      {$ENDIF}
    end;
  end;
end;

{$ENDIF}

end.
