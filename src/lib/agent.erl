-module(agent).
-behaviour(gen_server).

-export([init/1, handle_call/3, handle_cast/2, 
         handle_info/2, terminate/2, code_change/3]).

-export([start/0, create/3, auth/2]).

-include("common.hrl").
-include("schema.hrl").

-include_lib("eunit/include/eunit.hrl").

-define(AGENT(Name), {global, {agent, Name}}).
-define(LOOKUP_AGENT(Name), global:whereis_name({agent, Name})).

-record(agent, {
    cash = 0,           % cash balance
    credit = 0,         % credit balance, max owe to system.
    turnover = 0,       % today turnover
    subordinate = gb_trees:empty(),   % low level agent list
    players = gb_trees:empty(),
    record,             % tab_agent record
    disable = false
  }).

%% Server Function

init([R = #tab_agent{}]) when is_list(R#tab_agent.subordinate) ->
  {ok, #agent{ 
      disable = R#tab_agent.disable,
      players = setup_players(R#tab_agent.identity),
      subordinate = lists:foldl(fun(Sub, Acc) -> gb_trees:insert(Sub, 0, Acc) end, gb_trees:empty(), R#tab_agent.subordinate),
      record = R
    }
  }.

handle_cast(_Msg, Agent) ->
  {noreply, Agent}.

handle_call({betting, Player, Bet}, _From, Data) when is_list(Player), is_integer(Bet), Bet > 0 ->
  case gb_trees:lookup(Player, Data#agent.players) of
    none ->
      {reply, not_own_player, Data};
    {value, Val} ->
      {reply, ok, Data#agent{players = gb_trees:update(Player, Val + Bet, Data#agent.players)}}
  end;

handle_call({auth, ReqPwd}, _From, Agent = #agent{record = R}) when
    ReqPwd /= R#tab_agent.password ->
  {reply, false, Agent};

handle_call({auth, _Pwd}, _From, Data) ->
  {reply, true, Data};

handle_call(subordinate, _From, Data) ->
  {reply, gb_trees:keys(Data#agent.subordinate), Data};

handle_call(players, _From, Data) ->
  {reply, gb_trees:keys(Data#agent.players), Data};

handle_call({turnover, today}, _From, Data) ->
  {reply, lists:foldl(fun(Val, Sum) -> Val + Sum end, 0, gb_trees:values(Data#agent.players)), Data};

handle_call(kill, _From, Data) ->
  {stop, normal, ok, Data};

handle_call(_Msg, _From, Agent) ->
  {noreply, Agent}.

handle_info(_Msg, Server) ->
  {noreply, Server}.

code_change(_OldVsn, Server, _Extra) ->
  {ok, Server}.

terminate(normal, _Server) ->
  ok.

setup_players(Identity) when is_list(Identity) ->
  case mnesia:dirty_index_read(tab_player_info, Identity, agent) of
    Players when is_list(Players) ->
      lists:foldl(fun(Player, PlayersTree) -> gb_trees:insert(Player#tab_player_info.identity, 0, PlayersTree) end, 
        gb_trees:empty(), Players)
  end.

write(Agent = #tab_agent{}) ->
  {atomic, _Result} = mnesia:transaction(fun() -> mnesia:write(Agent) end).

%% Client Function

start() ->
  Fun = fun(R = #tab_agent{identity = Identity}, _Acc) when is_list(Identity) ->
      case ?LOOKUP_AGENT(Identity) of
        undefined -> {ok, _Pid} = gen_server:start(?AGENT(Identity), agent, [R], []);
        A -> ?LOG({live_agent, Identity, A})
      end
  end, 

  ok = mnesia:wait_for_tables([tab_agent], 1000),
  {atomic, _Result} = mnesia:transaction(fun() -> mnesia:foldl(Fun, nil, tab_agent) end).

kill() ->
  Fun = fun(R = #tab_agent{identity = Identity}, _Acc) ->
      case ?LOOKUP_AGENT(Identity) of
        Pid when is_pid(Pid) -> 
          ok = gen_server:call(Pid, kill);
        _ -> ok
      end
  end,

  {atomic, _Result} = mnesia:transaction(fun() -> mnesia:foldl(Fun, [], tab_agent) end).

create(Identity, Password, Parent) when is_list(Identity), is_list(Password), is_list(Parent) ->
  %%% check parent agent limit create count everyday
  %mnesia:transaction(fun() -> 
        %{atomic, ok} = mnesia:write_lock_table(tab_agent),
        %{atomic, Parent} = mnesia:read(tab_agent, Identity)
  %).
  ok.
      
auth(Identity, Password) when is_list(Identity), is_list(Password) ->
  gen_server:call(?AGENT(Identity), {auth, Password}).

betting(Identity, Player, Bet) when is_list(Identity), is_list(Player), is_integer(Bet), Bet > 0 ->
  gen_server:call(?AGENT(Identity), {betting, Player, Bet}).

turnover(Identity, today) when is_list(Identity) ->
  gen_server:call(?AGENT(Identity), {turnover, today}).

subordinate(Identity) when is_list(Identity) ->
  gen_server:call(?AGENT(Identity), subordinate).

players(Identity) when is_list(Identity) ->
  gen_server:call(?AGENT(Identity), players).
%% Eunit Test Case

subordinate_test() ->
  setup(),
  ?assertEqual(["agent_1_1"], subordinate("agent_1")),
  ?assertEqual(["agent_1", "disable_agent"], subordinate("root")).

players_test() ->
  setup(),
  ?assertEqual(["player_1", "player_2"], players("root")),
  ?assertEqual(["player_3"], players("agent_1")),
  ?assertEqual(["player_4"], players("agent_1_1")).

betting_test() ->
  setup(),
  ?assertEqual(not_own_player, betting("root", "player_3", 10)),
  ?assertEqual(ok, betting("root", "player_1", 10)),
  ?assertEqual(ok, betting("root", "player_2", 10)),
  ?assertEqual(ok, betting("root", "player_2", 30)),
  ?assertEqual(50, turnover("root", today)).

auth_test() ->
  setup(),
  ?assert(true =:= auth("root", "password")),
  ?assert(false =:= auth("root", "")).

%create_test() ->
  %setup().

setup() ->
  schema:uninstall(),
  schema:install(),
  schema:load_default_data(),

  DefPwd = "password",

  Agents = [
    #tab_agent{ 
      identity = "disable_agent", 
      password = DefPwd,
      parent = "root",
      disable = true
    }, #tab_agent{
      identity = "agent_1", 
      password = DefPwd,
      parent = root,
      subordinate = ["agent_1_1"]
    }, #tab_agent{
      identity = "agent_1_1",
      password = DefPwd,
      parent = "agent_1"
    }, #tab_agent{
      identity = "root",
      password = DefPwd,
      parent = nil,
      subordinate = ["disable_agent", "agent_1"]
    }
  ],

  Players = [
    #tab_player_info {
      pid = counter:bump(player),
      identity = "player_1",
      agent = "root"
    }, #tab_player_info {
      pid = counter:bump(player),
      identity = "player_2",
      agent = "root"
    }, #tab_player_info {
      pid = counter:bump(player),
      identity = "player_3",
      agent = "agent_1"
    }, #tab_player_info {
      pid = counter:bump(player),
      identity = "player_4",
      agent = "agent_1_1"
    }
  ],

  lists:foreach(fun(R) -> mnesia:dirty_write(R) end, Agents),
  lists:foreach(fun(R) -> mnesia:dirty_write(R) end, Players),

  kill(),
  start().
