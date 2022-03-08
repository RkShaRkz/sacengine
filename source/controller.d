// copyright © tg
// distributed under the terms of the gplv3 license
// https://www.gnu.org/licenses/gpl-3.0.txt

import std.stdio, std.algorithm, std.exception;
import util: Array;
import state, network, recording_;


final class Controller(B){
	GameState!B state;
	Network!B network;
	Recording!B recording, playback;
	int controlledSide;
	int commandId=0;
	int committedFrame;
	int lastCheckSynch=-1;
	int firstUpdatedFrame;
	int currentFrame;
	this(int controlledSide,GameState!B state,Network!B network,Recording!B recording,Recording!B playback){
		this.controlledSide=controlledSide;
		this.state=state;
		this.network=network;
		committedFrame=state.lastCommitted.frame;
		currentFrame=state.current.frame;
		firstUpdatedFrame=currentFrame;
		this.recording=recording;
		this.playback=playback;
		if(playback) state.commands=playback.commands;
		//initSynchState();
	}
	bool isControllingSide(int side){
		if(network&&!network.players[network.me].isControllingState)
			return false;
		return side==controlledSide;
	}
	void addCommand(int frame,Command!B command)in{
		assert(command.id==0);
		assert(!network||network.playing||command.type==CommandType.surrender);
		assert(committedFrame<=frame);
	}do{
		if(!isControllingSide(command.side)) return;
		command.id=++commandId;
		firstUpdatedFrame=min(firstUpdatedFrame,frame);
		state.addCommandInconsistent(frame,command);
		if(network) network.addCommand(frame,command);
		if(recording) recording.addCommand(frame,command);
		if(network && command.type==CommandType.surrender)
			updateNetworkOnSurrender(command.side);
	}
	void addCommand(Command!B command){
		if(network&&!network.playing) return;
		addCommand(currentFrame,command);
	}
	void addCommand(Command!B command,CommandQueueing queueing){
		command.queueing=queueing;
		addCommand(command);
	}
	void addExternalCommand(int frame,Command!B command)in{
		import std.conv: text;
		assert(committedFrame<=frame,text(committedFrame," ",frame," ",command));
	}do{
		// TODO: check if player that issued the command is allowed to do so
		firstUpdatedFrame=min(firstUpdatedFrame,frame);
		state.addCommandInconsistent(frame,command);
		if(recording) recording.addExternalCommand(frame,command);
		if(network && command.type==CommandType.surrender)
			updateNetworkOnSurrender(command.side);
	}
	void setSelection(int side,int wizard,CreatureGroup selection,TargetLocation loc){
		if(!isControllingSide(side)) return;
		addCommand(Command!B(CommandType.clearSelection,side,wizard,0,Target.init,float.init));
		foreach_reverse(id;selection.creatureIds){
			if(id==0) continue;
			addCommand(Command!B(CommandType.automaticToggleSelection,side,wizard,id,Target.init,float.init));
		}
	}
	void replaceState(scope ubyte[] serialized)in{
		assert(network&&!network.isHost);
	}do{
		import serialize_;
		deserialize(state.current,serialized);
		currentFrame=state.current.frame;
		static if(B.hasAudio) B.updateAudioAfterRollback();
		deserialize(state.commands,state.current,serialized);
		firstUpdatedFrame=state.current.frame;
		/+if(synchState.frame!=0){
			synchState.update(state.commands[synchState.frame].data);
			lastConfirmSynch=synchState.frame;
			synchState.serialized(&network.logDesynch);
			import std.conv:text;
			while(synchState.frame<state.current.frame){
				synchState.update(state.commands[synchState.frame].data);
			}
			enforce(synchState.frame==state.current.frame,text(synchState.frame," ",state.current.frame));
			writeln("SYNCHSTATE: ",synchState.frame," ",synchState.hash," CURRENTSTATE: ",state.current.frame," ",state.current.hash);
		}+/
		if(network.logDesynch_) state.lastCommitted.serialized(&network.logDesynch); // TODO: don't log if late join
		if(recording) recording.replaceState(state.lastCommitted,state.commands);
		network.updateStatus(PlayerStatus.stateResynched);
	}
	void logDesynch(int side,scope ubyte[] serialized){
		if(recording) recording.logDesynch(side,serialized,state.current);
	}
	/+int lastConfirmSynch=-1;
	ObjectState!B synchState;
	void initSynchState(){
		if(lastConfirmSynch==-1){
			synchState=new ObjectState!B(state.lastCommitted.map,state.lastCommitted.sides,state.lastCommitted.proximity,state.lastCommitted.pathFinder,state.lastCommitted.triggers);
			synchState.copyFrom(state.current);
			lastConfirmSynch=state.current.frame;
		}
	}
	void confirmSynch(int frame,int hash){
		import std.conv: text;
		enforce(synchState.frame<=lastConfirmSynch);
		enforce(lastConfirmSynch<=frame,text(lastConfirmSynch," ",frame));
		lastConfirmSynch=frame;
		while(synchState.frame<frame){
			synchState.update(state.commands[synchState.frame].data);
		}
		enforce(synchState.frame==frame && synchState.hash==hash,text("confirmed ",synchState.frame," ",synchState.hash,", but was ",hash));
	}+/
	void updateCommitted()in{
		assert(!!network);
	}do{
		committedFrame=network.committedFrame;
		if(!network.isHost&&network.desynched) return; // avoid simulating entire game after rejoin
		import std.conv: text;
		enforce(state.lastCommitted.frame<=committedFrame,text(state.lastCommitted.frame," ",committedFrame," ",network.players.map!((ref p)=>p.committedFrame)," ",network.activePlayerIds," ",network.players.map!((ref p)=>p.status)));
		if(state.commands.length<committedFrame+1)
			state.commands.length=committedFrame+1;
		assert(state.lastCommitted.frame<=firstUpdatedFrame);
		while(state.lastCommitted.frame<committedFrame){
			//playAudio=firstUpdatedFrame<=state.lastCommitted.frame;
			state.stepCommittedUnsafe();
			if(recording) recording.stepCommitted(state.lastCommitted);
			if(network.isHost) network.addSynch(state.lastCommitted.frame,state.lastCommitted.hash);
		}
		//playAudio=false;
		enforce(committedFrame==state.lastCommitted.frame,
		        text(network.activePlayerIds," ",network.players.map!((ref p)=>p.committedFrame)," ",
		             committedFrame," ",state.lastCommitted.frame));
		if(state.current.frame<committedFrame||state.current.frame==committedFrame&&firstUpdatedFrame<committedFrame)
			state.current.copyFrom(state.lastCommitted); // restore invariant
		currentFrame=max(currentFrame,committedFrame);
		firstUpdatedFrame=max(firstUpdatedFrame,committedFrame);
	}
	void updateNetworkGameState()in{
		assert(!!network);
	}do{
		foreach(ref p;network.players){
			if(p.slot==-1) continue;
			p.lostWizard|=!state.lastCommitted.isValidTarget(state.slots[p.slot].wizard,TargetType.creature);
		}
	}
	void updateNetworkOnSurrender(int side){
		foreach(ref p;network.players) if(p.slot!=-1&&state.slots[p.slot].controlledSide==side) p.lostWizard=true;
	}
	bool step(){
		playAudio=false;
		if(network){
			network.update(this);
			if(firstUpdatedFrame<currentFrame){
				// TODO: save multiple states, pick most recent with frame<=firstUpdatedFrame?
				import std.conv: text;
				enforce(state.lastCommitted.frame<=firstUpdatedFrame,text(state.lastCommitted.frame," ",firstUpdatedFrame," ",currentFrame));
				state.rollback();
			}
			if(network.isHost){ // handle new connections
				network.synchronizeMap(null);
				if(network.gameInitData){
					auto hash=network.hostSettings.mapHash;
					foreach(i,ref player;network.players){
						if(player.status==PlayerStatus.mapHashed && player.settings.mapHash==hash){
							network.updateStatus(cast(int)i,PlayerStatus.desynched);
							network.initGame(cast(int)i,network.gameInitData);
						}
					}
				}
			}
			if(network.isHost&&network.pauseOnDrop){
				if(network.anyoneDropped){
					network.pause(PlayerStatus.pausedOnDrop);
					network.acceptingNewConnections=true;
				}else if(network.players[network.me].status==PlayerStatus.pausedOnDrop){
					network.unpause();
				}
			}
			if(network.paused||network.hostDropped) return true;
			if(network.desynched){
				if(network.pendingResynch) network.updateStatus(PlayerStatus.readyToResynch);
				if(network.isHost && network.readyToResynch){
					network.acceptingNewConnections=false;
					import serialize_;
					//writeln("SENDING STATE AT FRAME: ",currentFrame," ",network.players.map!((ref p)=>p.committedFrame));
					import std.conv: text;
					enforce(currentFrame<=network.resynchCommittedFrame,text(currentFrame," ",network.resynchCommittedFrame," ",network.players.map!((ref p)=>p.status),network.players.map!((ref p)=>p.committedFrame)));
					currentFrame=network.resynchCommittedFrame;
					enforce(state.current.frame<=firstUpdatedFrame);
					if(state.commands.length<currentFrame+1)
						state.commands.length=currentFrame+1;
					state.simulateTo(currentFrame);
					firstUpdatedFrame=currentFrame;
					assert(state.current.frame==currentFrame);
					state.current.serialized((scope ubyte[] stateData){
						state.commands.serialized((scope ubyte[] commandData){
							foreach(i,ref player;network.players)
								network.sendState(cast(int)i,stateData,commandData);
						});
					});
					network.updateStatus(PlayerStatus.stateResynched);
				}
				if(network.stateResynched && network.players[network.me].status==PlayerStatus.stateResynched){
					//writeln("STATE IS ACTUALLY AT FRAME: ",currentFrame);
					enforce(firstUpdatedFrame==currentFrame);
					if(!network.isHost){
						state.lastCommitted.copyFrom(state.current);
						committedFrame=currentFrame;
						/+synchState.copyFrom(state.current);
						lastConfirmSynch=currentFrame;+/
					}
					if(network.players[network.me].committedFrame<currentFrame)
						network.commit(currentFrame);
					network.updateStatus(PlayerStatus.resynched);
				}
				if(network.isHost && network.resynched){
					updateCommitted();
					enforce(committedFrame==currentFrame);
					import std.conv: text;
					enforce(state.lastCommitted.hash==state.current.hash,text(state.lastCommitted.hash," ",state.current.hash));
					network.load();
				}
				return true; // ignore passed time in next frame
			}
			if(!network.playing){ // start game
				network.updateStatus(PlayerStatus.readyToStart);
				if(network.isHost&&network.readyToStart()){
					network.start(this);
				}
				return true; // ignore passed time in next frame
			}
			network.acceptingNewConnections=true;
		}else committedFrame=currentFrame;
		while(state.current.frame<currentFrame){
			playAudio=firstUpdatedFrame<=state.current.frame;
			state.step();
		}
		//state.simulateTo(currentFrame);
		playAudio=true;
		state.step();
		if(recording){
			recording.step();
			if(!network) recording.stepCommitted(state.current);
		}
		currentFrame=state.current.frame;
		firstUpdatedFrame=currentFrame;
		if(network){
			network.commit(currentFrame);
			playAudio=false;
			updateCommitted();
			updateNetworkGameState();
			if(!network.isHost&&lastCheckSynch<committedFrame){
				network.checkSynch(state.lastCommitted.frame,state.lastCommitted.hash);
				lastCheckSynch=committedFrame;
			}
		}else if(playback){
			if(auto replacement=playback.stateReplacement(state.current.frame)){
				assert(replacement.frame==state.current.frame);
				writeln("enountered state replacement at frame ",state.current.frame,replacement.hash!=state.current.hash?":":"");
				if(replacement.hash!=state.current.hash){
					import diff;
					diffStates(state.current,replacement);
					state.current.copyFrom(replacement);
				}
			}
			int side=-1;
			if(auto desynch=playback.desynch(state.current.frame,side)){
				writeln("player ",side," desynched at frame ",state.current.frame);
				if(desynch.hash!=state.current.hash){
					writeln("their state was replaced:");
					import diff;
					diffStates(desynch,state.current);
					//enforce(0);
				}
			}
		}
		return false;
	}
}
