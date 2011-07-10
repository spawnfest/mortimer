-module(game_server).
-include("records.hrl").
-include_lib("nitrogen_core/include/wf.hrl").
-behaviour(gen_server).
-export([start/2,start_link/2,stop/0,init/1,handle_call/3,terminate/2]).
-export([join/2,queue/2,leave/1,guess/2,ready/1,unready/1,title/1,name/1]).
-export([new_round/1,round_over/1]).



start(ID,Name) ->
	gen_server:start(?MODULE, {ID,Name}, []).

start_link(ID,Name) ->
	gen_server:start_link(?MODULE, {ID,Name}, []).

init({ID,Name}) ->
	GameRec = #game{
		name=Name,
		pid=self(),
		id=ID
	},
	{ok, GameRec}.

stop() ->
	gen_server:call(?MODULE,stop).

terminate(Reason,_State) ->
	{ok, Reason}.

handle_call(stop,_From,Game) ->
	{stop,ok,Game};

handle_call(title,_From,Game) ->
	{reply,Game#game.name,Game};

%% A player has joined the game
handle_call({join,Playername},{FromPid,_},Game) ->
	%% Set up the player's record with name and pid. 
	%% Score will default to 0 anyway, but we can set it manually for clarification's sake
	Player = #player{
		name=Playername,
		pid=FromPid,
		score=0,
		ready=false
	},

	%% Let's add the new player to the roster
	NewGame = Game#game{
		players=[{FromPid,Player} | Game#game.players]
	},

	%% Tell all the other players someone has joined
	to_all_players(NewGame,{join,Playername}),

	{reply,ok,NewGame};

%% A player has left the game
handle_call(leave,{FromPid,_},Game) ->
	%% Let's get the player's name
	Player = pl:get(Game#game.players,FromPid),
	Playername = Player#player.name,

	%% then we'll remove him from the list of players
	NewGame = Game#game{
		players=pl:delete(Game#game.players,FromPid)
	},


	%% Now we tell everyone someone was a lamer and left the game
	to_all_players(NewGame,{leave,Playername}),
	{reply,ok,NewGame};


%% A player has submitted a guess
handle_call({guess,Text},{FromPid,_},Game) ->
	Player = pl:get(Game#game.players,FromPid),

	if
		%% Don't honor guesses from the current player that's drawing
		FromPid == Game#game.drawing_pid -> 
			{reply,ok,Game};

		%% Don't honor guesses from someoen who's already gotten the answer
		Player#player.correct ->
			{reply,ok,Game};

		true ->
		
			%% Let's just compare lower case versions of the strings, shall we?
			NewG = string:to_lower(Text),
			Target = string:to_lower(Game#game.word),
			case NewG of
				Target -> 

					%% Tell everyone who got the current answer and for how many points
					to_all_players(Game,{correct,Player#player.name,10}),

					%% Update the player list to reflect the new score
					NewPlayer = Player#player{
						score=Player#player.score + 10,
						correct=true
					},
					NewGame = Game#game{
						players=pl:set(Game#game.players,FromPid,NewPlayer)
					},

					{reply,ok,NewGame};
				_ ->
					{reply,ok,Game}
			end
	end;
		

%% Someone has requested the list of players in this game	
handle_call(playerlist,_From,Game) ->
	Players = [P || {_,P} <- Game#game.players],
	{reply,Players,Game};


%% The Action (drawing) queue has been sent. Let's retransmit it
handle_call({queue,ActionList},{FromPid,_},Game) ->

	% We don't want to send it back to the player that sent it, so we use to_all_players_except/3
	to_all_players_except(Game,FromPid,{queue,ActionList}),
	{reply,ok,Game};


%% A player has marked himself as ready or unready
%% When the majority ( >50% ) of the players have readied up, we'll start
handle_call({ready,TF},{FromPid,_},Game) ->

	%% Let's get the player that's changed their ready status
	Player = pl:get(Game#game.players,FromPid),

	%% and update his status
	NewPlayer = Player#player{ready=TF},

	%% Then, let's put the updated player record back
	NewGame = Game#game{
		players=pl:set(Game#game.players,FromPid,NewPlayer)
	},
	
	%% Format the message to send to all players (ready or unready)
	Msg = case TF of
		true ->
			{ready,Player#player.name};
		false ->
			{unready,Player#player.name}
	end,

	%% Tell all the players of the updated status change
	to_all_players(NewGame,Msg),

	%% Let's check if we should start the game based on the number of players with ready=true
	case should_we_start(NewGame) of
		true ->
			%% Yeah, lets start
			%% But before we do, let's get a list of words and mark our game as "in progress" (going=true)
			%% When the words run out, we'll be done with this game
			StartGame = NewGame#game{
				words=word_server:get(10),
				going=true
			},
			
			%% Let all players know we're about to start the game
			to_all_players(NewGame,{game_starting}),

			%% Let players know who's going to be drawing next
			%% This is also triggered at the end of each round
			get_ready(NewGame),

			{reply,ok,StartGame};
		false ->
			{reply,ok,NewGame}
	end;

%% We're starting a new round
handle_call(new_round,_From,Game) ->

	%% Let's get the player that's next to draw
	[{NextPid,NextPlayer} | Players] = Game#game.players,

	%% And the new word
	[Word | Remaining] = Game#game.words,

	%% Now we'll inform the player who's next to draw that he's up
	to_player(NextPid,{you_are_up,Word}),

	%% And let everyone else know that we're starting a new round with that player up to draw
	to_all_players_except(Game,NextPid,{new_round,NextPlayer#player.name}),

	%% Let's put that player now to the back of the list so we doesn't draw again immediately
	NewPlayers = Players ++ [{NextPid,NextPlayer}],

	%% Now we'll make a timer that'll signal the end of the round
	%% We want to track the timer ref in case everyone gets it right
	%% In that event, we'll cancel the timer and just move on to the next round
	{ok,Tref} = timer:apply_after(60000,?MODULE,round_over,[self()]),

	%% Let's store all these exciting new changes in the new Game record
	NewGame = Game#game{
		players=NewPlayers,
		words=Remaining,
		drawing_pid = NextPid,
		word=Word,
		timer_refs = [Tref]
	},

	{reply,ok,NewGame};

%% The round is over
handle_call(round_over,_From,Game) ->

	%% Let everyone know the round is over
	to_all_players(Game,{round_over,Game#game.word}),

	%% No one is drawing right now
	NewGame = Game#game{
		drawing_pid=undefined
	},
	
	case length(Game#game.words) of

		%% If we don't have any words left, then the game is over
		0 -> 
			%% Let everyone know the game is over
			to_all_players(Game,{game_over}),

			%% Mark our game as done
			NewGame2 = NewGame#game{
				going=false
			},
			{reply,ok,NewGame2};

		%% If we do, then we have to get ready for the next round
		_ -> 
			get_ready(NewGame),
			{reply,ok,NewGame}
	end;


handle_call(Msg,_,Game) ->
	{reply,{error,unexpected_msg,Msg},Game}.


%% Simplifying the gen_server:call function to support for Pid and ID
game_call(Pid,Msg) when is_pid(Pid) ->
	gen_server:call(Pid,Msg);
game_call(ID,Msg) when is_integer(ID) ->
	Pid = game_master:get_pid(ID),
	game_call(Pid,Msg).





%% Sending Messages back to players

to_all_players(Game,Msg) ->
	to_player(all_player_pids(Game),Msg).

to_all_players_except(Game,ExceptPid,Msg) ->
	to_player(all_player_pids_except(Game,ExceptPid),Msg).

all_player_pids(Game) ->
	[Pid || {Pid,_} <- Game#game.players].

all_player_pids_except(Game,ExceptPid) ->
	lists:delete(ExceptPid,all_player_pids(Game)).
	

to_player(Pid,Msg) when is_pid(Pid) ->
	Pid ! Msg,
	ok;
to_player(Pids,Msg) when is_list(Pids)->
	[to_player(Pid,Msg) || Pid <- Pids],
	ok.
	

%% DrawAction is formatted based on what is sent from the javascript.
%% It doesn't matter to us, since we're just redistributing it to the clients
queue(Pid,ActionList) ->
	game_call(Pid,{queue,ActionList}).

guess(Pid,Text) ->
	game_call(Pid,{guess,Text}).

join(Pid,Name) ->
	game_call(Pid,{join,Name}).

leave(Pid) ->
	game_call(Pid,leave).

ready(Pid) ->
	game_call(Pid,{ready,true}).

unready(Pid) ->
	game_call(Pid,{ready,false}).

title(Pid) ->
	game_call(Pid,title).

exists(ID) ->
	game_master:exists(ID).

playerlist(Pid) ->
	game_call(Pid,playerlist).

name(Pid) ->
	title(Pid).

new_round(Pid) ->
	?PRINT({new_round,Pid}),
	game_call(Pid,new_round).


round_over(Pid) ->
	game_call(Pid,round_over).

%% Private functions


%% If more then 50% of the players are ready, return true
should_we_start(Game) ->
	Total = length(Game#game.players),
	Ready = length([P || {_,P} <- Game#game.players,P#player.ready==true]),
	Ready > Total/2.

%% Let everyone know who's drawing next
%% then in 5 seconds start the round officially
get_ready(Game) ->
	{NextPid,NextPlayer} = hd(Game#game.players),
	Playername = NextPlayer#player.name,
	to_all_players(Game,{get_ready,Playername}),
	timer:apply_after(5000,?MODULE,new_round,[self()]).
