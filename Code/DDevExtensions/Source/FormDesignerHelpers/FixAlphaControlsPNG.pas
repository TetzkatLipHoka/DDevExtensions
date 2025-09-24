unit FixAlphaControlsPNG;

{$I ..\DelphiExtension.inc}
{.$DEFINE PNGGraphicBMP}

interface

{$IFDEF COMPILER12_UP}

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

{$ENDIF COMPILER12_UP}

implementation

uses
  pnglang;

{$IFDEF COMPILER12_UP}

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
      TPicture.RegisterFileFormat('', 'Portable network graphics (AlphaControls)', TPNGGraphic)
    else
      TPicture.UnregisterGraphicClass(TPNGGraphic);
  end;
end;

{$ENDIF COMPILER12_UP}

end.
