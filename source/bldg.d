import std.exception, std.string;
import util;

enum BldgFlags:uint{
	none=0,
	unknown=1<<3,
	ground=1<<31,
}

struct BldgHeader{
	BldgFlags flags;
	ubyte[8][8] ground;
	float x,y,z;
	float facing;
	float unknown1;
	ubyte[24] unknown2;
	char[4] tileset;
	char[4] unknown3;
	uint numComponents;
	char[4] base;
}
static assert(BldgHeader.sizeof==128);
struct BldgComponent{
	char[4] kind;
	char[4] retroModel;
	char[4] unknown0;
	char[4] destroyed;
	float unknown1;
	float x,y,z;
	float facing;
	ubyte[8] unknown2;
	char[4] unknown3;
}
static assert(BldgComponent.sizeof==48);

struct Bldg{
	BldgHeader* header;
	alias header this;
	BldgComponent[] components;
}

Bldg parseBldg(ubyte[] data){
	auto header=cast(BldgHeader*)data[0..BldgHeader.sizeof].ptr;
	enforce(data.length==BldgHeader.sizeof+header.numComponents*BldgComponent.sizeof);
	auto components=cast(BldgComponent[])data[BldgHeader.sizeof..$];
	auto bldg=Bldg(header,components);
	return bldg;
}

Bldg loadBldg(string filename){
	enforce(filename.endsWith(".BLDG"));
	return parseBldg(readFile(filename));
}