// copyright © tg
// distributed under the terms of the gplv3 license
// https://www.gnu.org/licenses/gpl-3.0.txt

import std.stdio, std.algorithm, std.exception;
import util: Array, assignArray;
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
		if(playback) assignArray(state.commands,playback.commands);
	}
	void addCommand(int frame,Command!B command)in{
		assert(command.id==0);
		assert(!network||network.playing||command.type==CommandType.surrender);
		assert(committedFrame<=frame);
	}do{
		if(command.side!=controlledSide) return;
		command.id=++commandId;
		firstUpdatedFrame=min(firstUpdatedFrame,frame);
		state.addCommandInconsistent(frame,command);
		if(network) network.addCommand(frame,command);
		if(recording) recording.addCommand(frame,command);
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
		firstUpdatedFrame=min(firstUpdatedFrame,frame);
		state.addCommandInconsistent(frame,command);
		if(recording) recording.addExternalCommand(frame,command);
	}
	void replaceState(scope ubyte[] serialized)in{
		assert(network&&!network.isHost);
	}do{
		import serialize_;
		state.lastCommitted.serialized(&network.logDesynch); // TODO: don't log if late join
		deserialize(state.current,serialized);
		currentFrame=state.current.frame;
		static if(B.hasAudio) B.updateAudioAfterRollback();
		deserialize(state.commands,state.current,serialized);
		firstUpdatedFrame=state.current.frame;
		if(recording) recording.replaceState(state.lastCommitted,state.commands);
		if(network) network.updateStatus(PlayerStatus.stateResynched);
	}
	void logDesynch(int side,scope ubyte[] serialized){
		if(recording) recording.logDesynch(side,serialized,state.current);
	}
	void setSelection(int side,int wizard,CreatureGroup selection,TargetLocation loc){
		if(side!=controlledSide) return;
		addCommand(Command!B(CommandType.clearSelection,side,wizard,0,Target.init,float.init));
		foreach_reverse(id;selection.creatureIds){
			if(id==0) continue;
			addCommand(Command!B(CommandType.automaticToggleSelection,side,wizard,id,Target.init,float.init));
		}
	}
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
			state.stepCommittedUnsafe();
			if(recording) recording.stepCommitted(state.lastCommitted);
			if(network.isHost) network.addSynch(state.lastCommitted.frame,state.lastCommitted.hash);
		}
		enforce(committedFrame==state.lastCommitted.frame,
		        text(network.activePlayerIds," ",network.players.map!((ref p)=>p.committedFrame)," ",
		             committedFrame," ",state.lastCommitted.frame));
		if(state.current.frame<committedFrame)
			state.current.copyFrom(state.lastCommitted); // restore invariant
		currentFrame=max(currentFrame,committedFrame);
		firstUpdatedFrame=max(firstUpdatedFrame,committedFrame);
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
							//network.load(cast(int)i);
							network.updateStatus(cast(int)i,PlayerStatus.desynched);
							network.initGame(cast(int)i,network.gameInitData);
						}
					}
				}
			}
			if(network.desynched){
				network.acceptingNewConnections=false;
				if(!network.players[network.me].status.among(PlayerStatus.readyToResynch,PlayerStatus.stateResynched,PlayerStatus.resynched,PlayerStatus.loading))
					network.updateStatus(PlayerStatus.readyToResynch);
				if(network.isHost && network.readyToResynch){
					import serialize_;
					currentFrame=network.resynchCommittedFrame; // commits have to be monotone
					//writeln("SENDING STATE AT FRAME: ",currentFrame," ",network.players.map!((ref p)=>p.committedFrame));
					//if(state.commands.length<currentFrame+1)
					state.commands.length=currentFrame+1;
					state.rollback(currentFrame);
					assert(state.current.frame==currentFrame);
					firstUpdatedFrame=currentFrame;
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
					}
					if(network.players[network.me].committedFrame<currentFrame)
						network.commit(currentFrame);
					network.updateStatus(PlayerStatus.resynched);
				}
				if(network.isHost && network.resynched){
					updateCommitted();
					enforce(committedFrame==currentFrame);
					network.load();
				}
				return true; // ignore passed time in next frame
			}
			if(!network.playing){ // start game
				network.updateStatus(PlayerStatus.readyToStart);
				if(network.isHost&&network.readyToStart()){
					network.start(this);
				}
				network.acceptingNewConnections=true;
				return true; // ignore passed time in next frame
			}
		}else committedFrame=currentFrame;
		state.simulateTo(currentFrame);
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
				}
			}
		}
		return false;
	}
}
