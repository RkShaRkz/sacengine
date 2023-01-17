import options:Options,Settings;
import sids, sacmap, state, controller, network, recording_;
import util;
import std.string, std.range, std.algorithm, std.stdio;
import std.exception, std.conv;

GameInit!B gameInit(B,R)(Sides!B sides_,R playerSettings,ref Options options){
	GameInit!B gameInit;
	auto numSlots=options.numSlots;
	if(options._2v2) enforce(numSlots>=4);
	if(options._3v3) enforce(numSlots>=6);
	gameInit.slots=new GameInit!B.Slot[](numSlots);
	auto sides=iota(numSlots).map!(i=>sides_.multiplayerSide(i)).array;
	if(options.shuffleSides){
		import std.random: randomShuffle;
		randomShuffle(sides);
	}
	auto teams=(-1).repeat(numSlots).array;
	if(options.ffa||options._2v2||options._3v3){
		int teamSize=1;
		if(options._2v2) teamSize=2;
		if(options._3v3) teamSize=3;
		foreach(slot,ref team;teams)
			team=cast(int)slot/teamSize;
	}else{
		foreach(ref settings;playerSettings)
			if(settings.slot!=-1)
				teams[settings.slot]=settings.team;
	}
	if(options.shuffleTeams){
		import std.random: randomShuffle;
		randomShuffle(teams);
	}
	void placeWizard(ref Settings settings){
		if(settings.observer) return;
		import std.random: uniform;
		int slot=settings.slot;
		if(slot<0||slot>=numSlots||gameInit.slots[slot].wizardIndex!=-1)
			return;
		char[4] tag=settings.wizard[0..4];
		if(options.randomWizards){
			import nttData:wizards;
			tag=cast(char[4])wizards[uniform!"[)"(0,$)];
		}
		auto name=settings.name;
		auto side=sides[settings.slot];
		auto level=settings.level;
		auto souls=settings.souls;
		float experience=0.0f;
		auto minLevel=settings.minLevel;
		auto maxLevel=settings.maxLevel;
		auto xpRate=settings.xpRate;
		auto spells=settings.spellbook;
		if(options.randomGods) spells=defaultSpells[uniform!"[]"(1,5)];
		if(options.randomSpellbooks) spells=randomSpells();
		auto spellbook=getSpellbook!B(spells);
		import nttData:WizardTag;
		assert(gameInit.slots[slot]==GameInit!B.Slot(-1));
		int wizardIndex=cast(int)gameInit.wizards.length;
		gameInit.slots[slot]=GameInit!B.Slot(wizardIndex);
		gameInit.wizards~=GameInit!B.Wizard(to!WizardTag(tag),name,side,level,souls,experience,minLevel,maxLevel,xpRate,spellbook);
	}
	foreach(ref settings;playerSettings) placeWizard(settings);
	if(options.shuffleSlots){
		import std.random: randomShuffle;
		randomShuffle(zip(gameInit.slots,teams));
	}
	foreach(i;0..numSlots){
		foreach(j;i+1..numSlots){
			int wi=gameInit.slots[i].wizardIndex, wj=gameInit.slots[j].wizardIndex;
			if(wi==-1||wj==-1) continue;
			int s=gameInit.wizards[wi].side, t=gameInit.wizards[wj].side;
			if(s==-1||t==-1) continue;
			assert(s!=t);
			int x=teams[i], y=teams[j];
			auto stance=x!=-1&&y!=-1&&x==y?Stance.ally:Stance.enemy;
			gameInit.stanceSettings~=GameInit!B.StanceSetting(s,t,stance);
			gameInit.stanceSettings~=GameInit!B.StanceSetting(t,s,stance);
		}
	}
	if(options.mirrorMatch){
		int[int] teamLoc;
		int[][] teamIndex;
		foreach(slot;0..numSlots) if(teams[slot]!=-1){
			if(teams[slot]!in teamLoc){
				teamLoc[teams[slot]]=cast(int)teamIndex.length;
				teamIndex~=[[]];
			}
			teamIndex[teamLoc[teams[slot]]]~=slot;
		}
		foreach(slot;0..numSlots) if(teams[slot]<0) teamIndex~=[slot];
		teamIndex.sort!("a.length > b.length",SwapStrategy.stable);
		foreach(t;teamIndex[1..$]){
			foreach(i;0..t.length){
				void copyWizard(T)(ref T a,ref T b){
					if(options.randomWizards) a.tag=b.tag;
					a.spellbook=b.spellbook;
				}
				copyWizard(gameInit.wizards[t[i]],gameInit.wizards[teamIndex[0][i]]);
			}
		}
	}
	gameInit.replicateCreatures=options.replicateCreatures;
	gameInit.protectManafounts=options.protectManafounts;
	gameInit.terrainSineWave=options.terrainSineWave;
	return gameInit;
}

enum LobbyState{
	empty,
	initialized,
	offline,
	connected,
	synched,
	hashesReady,
	incompatibleVersion,
	waitingForClients,
	readyToLoad,
}

struct Lobby(B){
	LobbyState state;
	Network!B network=null;
	InternetAddress joinAddress=null;
	int slot;
	bool isHost(){ return !network||network.isHost; }
	Recording!B playback=null;
	Recording!B toContinue=null;

	SacMap!B map;
	ubyte[] mapData;
	Sides!B sides;
	Proximity!B proximity;
	PathFinder!B pathFinder;
	Triggers!B triggers;

	GameState!B gameState;
	GameInit!B gameInit;
	Recording!B recording=null;

	bool hasSlot;
	int wizId;
	Controller!B controller;

	void initialize(int slot,ref Options options)in{
		assert(state==LobbyState.empty);
	}do{
		this.slot=slot;
		state=LobbyState.initialized;
	}

	private void createNetwork(ref Options options)in{
		assert(!network);
	}do{
		network=new Network!B();
		network.dumpTraffic=options.dumpTraffic;
		network.checkDesynch=options.checkDesynch;
		network.logDesynch_=options.logDesynch;
		network.pauseOnDrop=options.pauseOnDrop;
	}

	bool tryConnect(ref Options options)in{
		assert(state==LobbyState.initialized);
	}do{
		if(options.host){
			if(!network) createNetwork(options);
			network.hostGame(options.settings);
			state=LobbyState.connected;
			return true;
		}
		if(options.joinIP!=""){
			if(!network) createNetwork(options);
			if(!joinAddress) joinAddress=new InternetAddress(options.joinIP,listeningPort);
			auto result=network.joinGame(joinAddress,options.settings);
			if(result) state=LobbyState.connected;
			return result;
		}
		state=LobbyState.offline;
		return true;
	}

	bool canPlayRecording(){ return state==LobbyState.offline && !playback && !toContinue; }
	void initializePlayback(Recording!B recording,ref Options options)in{
		assert(canPlayRecording);
	}do{
		playback=recording;
		enforce(playback.mapName.endsWith(".scp")||playback.mapName.endsWith(".HMAP"));
		options.map=playback.mapName;
		slot=-1;
		map=playback.map;
		sides=playback.sides;
		proximity=playback.proximity;
		pathFinder=playback.pathFinder;
		triggers=playback.triggers;
		options.mapHash=map.crc32;
	}

	bool canContinue(){ return state.among(LobbyState.offline, LobbyState.connected) && isHost && !toContinue && !playback; }
	void continueGame(Recording!B recording,int frame,ref Options options)in{
		assert(canContinue);
	}do{
		toContinue=recording;
		if(frame!=-1){
			toContinue.commands.length=frame;
			toContinue.commands~=Array!(Command!B)();
		}else{
			if(toContinue.commands[$-1].length) toContinue.commands~=Array!(Command!B)();
			frame=max(0,to!int(toContinue.commands.length)-1);
			options.continueFrame=frame;
		}
		options.map=toContinue.mapName;
		if(network) network.hostSettings=options.settings;
		options.numSlots=to!int(toContinue.gameInit.slots.length);
		map=toContinue.map;
		sides=toContinue.sides;
		proximity=toContinue.proximity;
		pathFinder=toContinue.pathFinder;
		triggers=toContinue.triggers;
		if(network){
			assert(state==LobbyState.connected);
			static struct SlotData{
				int slot;
				string name;
			}
			SlotData toSlotData(int i){
				return SlotData(i,toContinue.gameInit.wizards[toContinue.gameInit.slots[i].wizardIndex].name);
			}
			assert(network.players.length==1);
			network.players[network.me].committedFrame=frame;
			network.initSlots(iota(options.numSlots).map!toSlotData);
		}else assert(state==LobbyState.offline);
		options.mapHash=map.crc32;
	}

	bool trySynch(){
		network.update(controller); // (may be null)
		bool result=network.synched;
		if(result) state=LobbyState.synched;
		return result;
	}

	bool synchronizeSettings(ref Options options)in{
		assert(!!network);
		with(LobbyState) assert(state.among(synched,hashesReady,waitingForClients,readyToLoad));
	}do{
		if(state<LobbyState.hashesReady){
			if(isHost) loadMap(options);
			network.updateSetting!"mapHash"(options.mapHash);
			network.updateStatus(PlayerStatus.commitHashReady);
			state=LobbyState.hashesReady;
		}
		if(state==LobbyState.hashesReady){
			if(!network.isHost){
				network.update(controller); // (may be null)
				if(!network.hostCommitHashReady)
					return false;
				if(network.hostSettings.commit!=options.commit){
					writeln("incompatible version #");
					writeln("host is using version ",network.hostSettings.commit);
					network.disconnectPlayer(network.host,null);
					state=LobbyState.incompatibleVersion;
					return true;
				}
				network.updateStatus(PlayerStatus.readyToLoad);
			}
			state=LobbyState.waitingForClients;
		}
		if(state==LobbyState.waitingForClients){
			network.update(controller); // (may be null)
			if(!network.readyToLoad&&!network.pendingResynch){
				if(network.isHost&&network.numReadyPlayers+(network.players[network.host].wantsToControlState)>=options.numSlots&&network.clientsReadyToLoad()){
					network.acceptingNewConnections=false;
					//network.stopListening();
					auto numSlots=options.numSlots;
					auto slotTaken=new bool[](numSlots);
					foreach(i,ref player;network.players){
						if(player.settings.observer) continue;
						auto pslot=player.settings.slot;
						if(0<=pslot && pslot<options.numSlots && !slotTaken[pslot])
							slotTaken[pslot]=true;
						else pslot=-1;
						network.updateSlot(cast(int)i,pslot);
					}
					auto freeSlots=iota(numSlots).filter!(i=>!slotTaken[i]);
					foreach(i,ref player;network.players){
						if(player.settings.observer) continue;
						if(freeSlots.empty) break;
						if(player.slot==-1){
							network.updateSlot(cast(int)i,freeSlots.front);
							freeSlots.popFront();
						}
					}
					if(options.synchronizeLevel) network.synchronizeSetting!"level"();
					if(options.synchronizeSouls) network.synchronizeSetting!"souls"();

					if(options.synchronizeLevelBounds){
						network.synchronizeSetting!"minLevel"();
						network.synchronizeSetting!"maxLevel"();
					}
					if(options.synchronizeXPRate) network.synchronizeSetting!"xpRate"();

					network.updateStatus(PlayerStatus.readyToLoad);
					assert(network.readyToLoad());
					state=LobbyState.readyToLoad;
				}else return false;
			}
		}
		if(!network.isHost){
			if(!map){
				auto mapName=network.hostSettings.map;
				network.updateSetting!"map"(mapName);
				auto hash=network.hostSettings.mapHash;
				import std.file: exists;
				if(exists(mapName)){
					map=loadSacMap!B(mapName); // TODO: compute hash without loading map?
					options.mapHash=map.crc32;
				}
				network.updateSetting!"mapHash"(options.mapHash);
				network.updateStatus(PlayerStatus.mapHashed);
			}
		}else{
			network.mapData=mapData;
			network.updateStatus(PlayerStatus.mapHashed);
		}
		void loadMap(string mapName){
			options.map=mapName;
			map=loadSacMap!B(mapName);
			options.mapHash=map.crc32;
			auto hash=network.hostSettings.mapHash;
			enforce(options.mapHash==hash,"map hash mismatch");
			network.updateSetting!"mapHash"(options.mapHash);
			network.updateStatus(PlayerStatus.mapHashed);
		}
		network.update(controller); // (may be null)
		if(!network.synchronizeMap(&loadMap))
			return false;
		if(network.isHost){
			network.load();
		}else{
			if(!network.loading&&network.players[network.me].status!=PlayerStatus.desynched) // desynched at start if late join
				return false;
		}
		options.settings=network.settings;
		slot=network.slot;
		state=LobbyState.readyToLoad;
		return true;
	}

	void loadMap(ref Options options){
		if(!map) map=loadSacMap!B(options.map,&mapData); // TODO: compute hash without loading map?
		options.mapHash=map.crc32; // TODO: store this somewhere else?
		if(state==LobbyState.offline) state=LobbyState.readyToLoad;
	}

	bool loadGame(ref Options options)in{
		assert(!!map);
		assert(state==LobbyState.readyToLoad);
	}do{
		void initState(){
			if(!gameState){
				sides=new Sides!B(map.sids);
				proximity=new Proximity!B();
				pathFinder=new PathFinder!B(map);
				triggers=new Triggers!B(map.trig);
				gameState=new GameState!B(map,sides,proximity,pathFinder,triggers);
			}
		}
		if(!playback||network){
			if(network){
				import serialize_;
				if(network.isHost){
					initState();
					if(toContinue) gameInit=toContinue.gameInit;
					else gameInit=.gameInit!B(sides,network.players.map!(ref(return ref x)=>x.settings),options);
					gameInit.serialized(&network.initGame);
				}else{
					network.update(controller); // (may be null)
					if(!network.gameInitData)
						return false;
					initState();
					deserialize(gameInit,gameState.current,network.gameInitData);
					network.gameInitData=null;
				}
			}else{
				initState();
				if(toContinue) gameInit=toContinue.gameInit;
				else gameInit=.gameInit!B(sides,only(options.settings),options);
			}
		}else gameInit=playback.gameInit;
		if((!playback||network)&&options.recordingFilename.length){
			recording=new Recording!B(options.map,map,sides,proximity,pathFinder,triggers);
			recording.gameInit=gameInit;
			recording.logCore=options.logCore;
		}
		gameState.initGame(gameInit);
		hasSlot=0<=slot&&slot<=gameState.slots.length;
		wizId=hasSlot?gameState.slots[slot].wizard:0;
		gameState.current.map.makeMeshes(options.enableMapBottom);
		if(toContinue){
			gameState.commands=toContinue.commands;
			playAudio=false;
			while(gameState.current.frame+1<gameState.commands.length){
				gameState.step();
				if(gameState.current.frame%1000==0){
					writeln("continue: simulated ",gameState.current.frame," of ",gameState.commands.length-1," frames");
				}
			}
			playAudio=true;
			writeln(gameState.current.frame," ",options.continueFrame);
			assert(gameState.current.frame==options.continueFrame);
			if(network){
				assert(network.isHost);
				foreach(i;network.connectedPlayerIds) if(i!=network.host) network.updateStatus(cast(int)i,PlayerStatus.desynched);
				network.continueSynchAt(options.continueFrame);
			}
		}
		gameState.commit();
		if(network && network.isHost) network.addSynch(gameState.lastCommitted.frame,gameState.lastCommitted.hash);
		if(recording) recording.stepCommitted(gameState.lastCommitted);
		controller=new Controller!B(hasSlot?slot:-1,gameState,network,recording,playback);
		return true;
	}

	bool update(ref Options options)in{
		with(LobbyState)
		assert(state.among(offline,connected,synched,hashesReady,waitingForClients,readyToLoad));
	}do{
		if(network){
			if(state==LobbyState.connected){
				if(!trySynch())
					return false;
			}
			with(LobbyState)
			if(state.among(synched,hashesReady,waitingForClients,readyToLoad)){
				if(!synchronizeSettings(options))
					return false;
			}
		}else loadMap(options);
		assert(!!map);
		if(state==LobbyState.readyToLoad){
			if(!loadGame(options))
				return false;
		}
		return true;
	}
}
