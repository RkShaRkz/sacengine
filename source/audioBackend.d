import dlib.math;
import std.container, std.algorithm: swap;
import audio, samp, nttData, maps, state;

enum Theme{
	normal,
	battle1,
	battle2,
	battle3,
	battle4,
	battle5,
	losing,
	winning,
	menu,
	none,
}
class AudioBackend(B){
	MP3[Theme.max] themes;
	MP3 sacrifice1;
	MP3 defeat;
	MP3 victory;
	auto currentTheme=Theme.none;
	auto nextTheme=Theme.none;
	float musicGain;
	float soundGain;
	float themeGain=1.0f;
	enum _3dSoundVolumeMultiplier=6.0f;
	this(float volume,float musicVolume,float soundVolume){
		musicGain=volume*musicVolume;
		soundGain=volume*soundVolume;
		themes[Theme.battle1]=MP3("extracted/music/Battle 1.mp3");
		themes[Theme.battle2]=MP3("extracted/music/Battle 2.mp3");
		themes[Theme.battle3]=MP3("extracted/music/Battle 3.mp3");
		themes[Theme.battle4]=MP3("extracted/music/Battle 4.mp3");
		themes[Theme.battle5]=MP3("extracted/music/Battle 5.mp3");
		themes[Theme.losing]=MP3("extracted/music/Sacrifice Losing.mp3");
		themes[Theme.winning]=MP3("extracted/music/Sacrifice Victory.mp3");
		themes[Theme.menu]=MP3("extracted/music/menu.mp3");
		sacrifice1=MP3("extracted/music/Sacrifice 1.mp3");
		defeat=MP3("extracted/music/Defeat Theme.mp3");
		victory=MP3("extracted/music/Victory Theme.mp3");

		sounds1.reserve(20);
		sounds2.reserve(20);
		sounds3.reserve(20);
	}
	void setTileset(Tileset tileset){
		themes[Theme.normal]=MP3(godThemes[tileset]);
	}
	void switchTheme(Theme next){
		nextTheme=next;
	}
	enum fadeOutTime=0.5f;
	void updateTheme(float dt){
		if(nextTheme!=currentTheme){
			if(currentTheme==Theme.none){
				currentTheme=nextTheme;
				themes[currentTheme].source.gain=musicGain;
				themes[currentTheme].play();
			}else{
				themeGain-=(1.0f/fadeOutTime)*dt;
				if(themeGain<=0.0f){
					themeGain=1.0f;
					themes[currentTheme].stop();
					themes[currentTheme].source.gain=musicGain;
					currentTheme=nextTheme;
					if(currentTheme!=Theme.none) themes[currentTheme].play();
				}else themes[currentTheme].source.gain=themeGain*musicGain;
			}
		}
		if(currentTheme!=Theme.none) themes[currentTheme].feed();
	}
	struct Sound1{
		Source source;
		Vector3f position;
	}
	Array!Sound1 sounds1;
	struct Sound2{
		Source source;
		int id;
	}
	Array!Sound2 sounds2;
	struct LoopSound{
		Source source;
		int id;
	}
	Array!LoopSound sounds3;

	Buffer[char[4]] buffers;
	Buffer getBuffer(char[4] sound){
		if(sound in buffers) return buffers[sound];
		return buffers[sound]=makeBuffer(loadSAMP(samps[sound]));
	}

	void playSoundAt(char[4] sound,Vector3f position){
		auto source=makeSource();
		source.gain=soundGain*_3dSoundVolumeMultiplier;
		source.buffer=getBuffer(sound);
		sounds1~=Sound1(source,position);
	}
	void playSoundAt(char[4] sound,int id){
		auto source=makeSource();
		source.gain=soundGain*_3dSoundVolumeMultiplier;
		source.buffer=getBuffer(sound);
		sounds2~=Sound2(source,id);
	}
	void loopSoundAt(char[4] sound,int id){
		auto source=makeSource();
		source.gain=soundGain*_3dSoundVolumeMultiplier;
		source.buffer=getBuffer(sound);
		source.looping=true;
		sounds3~=LoopSound(source,id);
	}

	void updateSounds(float dt,Matrix4f viewMatrix,ObjectState!B state){
		for(int i=0;i<sounds1.length;){
			if(sounds1[i].source.isInitial)
				sounds1[i].source.play();
			else if(!sounds1[i].source.isPlaying){
				swap(sounds1[i],sounds1[$-1]);
				sounds1[$-1].source.release();
				sounds1.length=sounds1.length-1;
				continue;
			}
			sounds1[i].source.position=sounds1[i].position*viewMatrix;
			i++;
		}
		for(int i=0;i<sounds2.length;){
			if(sounds2[i].source.isInitial)
				sounds2[i].source.play();
			else if(!sounds2[i].source.isPlaying){
				swap(sounds2[i],sounds2[$-1]);
				sounds2[$-1].source.release();
				sounds2.length=sounds2.length-1;
				continue;
			}
			if(state.isValidId(sounds2[i].id))
				sounds2[i].source.position=state.objectById!((obj)=>obj.center)(sounds2[i].id)*viewMatrix;
			i++;
		}
		for(int i=0;i<sounds3.length;){
			if(sounds3[i].source.isInitial)
				sounds3[i].source.play();
			if(!state.isValidId(sounds3[i].id)){
				swap(sounds3[i],sounds3[$-1]);
				sounds3[$-1].source.stop();
				sounds3[$-1].source.release();
				sounds3.length=sounds3.length-1;
				continue;
			}
			sounds3[i].source.position=state.objectById!((obj)=>obj.center)(sounds3[i].id)*viewMatrix;
			i++;
		}
	}

	void update(float dt,Matrix4f viewMatrix,ObjectState!B state){
		updateTheme(dt);
		updateSounds(dt,viewMatrix,state);
	}
	void release(){
		foreach(ref theme;themes) theme.release();
		sacrifice1.release();
		defeat.release();
		victory.release();
		foreach(i;0..sounds1.length) sounds1[i].source.release();
		sounds1.length=0;
		foreach(i;0..sounds2.length) sounds2[i].source.release();
		sounds2.length=0;
		foreach(i;0..sounds3.length) sounds3[i].source.release();
		sounds3.length=0;
		foreach(k,v;buffers) v.release();
	}
	~this(){ release(); }
}
