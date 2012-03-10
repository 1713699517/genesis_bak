-module(sim_client).
-compile([export_all]).

-include("common.hrl").
-include("game.hrl").
-include("schema.hrl").
-include("protocol.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(SLEEP, timer:sleep(100)).

-define(DEF_HASH_PWD, erlang:phash2(?DEF_PWD, 1 bsl 32)).


-record(pdata, {
    box = [],
    host = ?UNDEF
  }).

%%%
%%% client
%%%

start() ->
  start(sim_client).

start(Id) when is_atom(Id) ->
  kill(Id),
  PID = spawn(?MODULE, loop, [fun client:loop/2, self()]),
  true = register(Id, PID),
  PID.

kill(Id) ->
  catch where(Id) ! kill,
  ?SLEEP.

kill_games() ->
  kill_games(1),
  ?SLEEP.

kill_games(N) ->
  case kill_game(N) of
    ok -> kill_games(N+1);
    undefined -> ok
  end.

kill_game(Id) ->
  case where_game(Id) of
    Game when is_pid(Game) ->
      gen_server:call(Game, kill);
    undefined ->
      undefined
  end.

kill_player(Identity) ->
  case where_player(Identity) of
    Player when is_pid(Player) ->
      gen_server:call(Player, kill);
    undefined ->
      undefined
  end.
  
where(Id) ->
  whereis(Id).

where_game(Id) ->
  ?LOOKUP_GAME(Id).

where_player(Identity) ->
  ?LOOKUP_PLAYER(Identity).
  
send(Id, R) ->
  Id ! {send, R},
  ?SLEEP.

head(Id) ->
  Id ! {head, self()},
  receive 
    R when is_tuple(R) -> R
  after
    500 -> exit(request_timeout)
  end.

box() ->
  receive
    Box when is_list(Box) -> Box
  after
    500 -> exit(request_timeout)
  end.

box(Id) ->
  Id ! {box, self()},
  receive 
    Box when is_list(Box) -> Box
  after
    500 -> exit(request_timeout)
  end.

loopdata(Id, Key) ->
  Id ! {loopdata, Key, self()},
  receive 
    LoopDataVal -> LoopDataVal
  after
    500 -> exit(request_timeout)
  end.

players() ->
  [
    {jack, #tab_player_info{
        pid = 1, 
        identity = "jack", 
        nick = "Jack",
        photo = "default",
        password = ?DEF_HASH_PWD,
        disabled = false }},
    {tommy, #tab_player_info{
        pid = 2, 
        identity = "tommy", 
        nick = "Tommy",
        photo = "default",
        password = ?DEF_HASH_PWD,
        disabled = false }}
  ].

player(Identity) when is_atom(Identity) ->
  {Identity, Data} = proplists:lookup(Identity, players()),
  Data.

%%%
%%% callback
%%%

loop(Fun, Host) ->
  loop(Fun, ?UNDEF, #pdata{host = Host}).

loop(Fun, ?UNDEF, Data = #pdata{}) ->
  LoopData = Fun(connected, ?UNDEF),
  loop(Fun, LoopData, Data);

loop(Fun, LoopData, Data = #pdata{box = Box}) ->
  receive
    kill ->
      exit(kill);
    %% clien module callback close connection.
    close ->
      Data#pdata.host ! Box,
      exit(normal);
    %% clien module callback send bianry to remote client.
    {send, Bin} when is_binary(Bin) ->
      R = protocol:read(Bin),
      NB = Box ++ [R], %% insert new message to box
      loop(Fun, LoopData, Data#pdata{box = NB});
    %% send protocol record to clinet module.
    {send, R} when is_tuple(R) ->
      ND = Fun({recv, list_to_binary(protocol:write(R))}, LoopData),
      loop(Fun, ND, Data); %% sim socket binary data
    %% host process get message box head one.
    {head, From} when is_pid(From) ->
      case Box of
        [H|T] ->
          From ! H,
          loop(Fun, LoopData, Data#pdata{box = T});
        [] ->
          loop(Fun, LoopData, Data#pdata{box = []})
      end;
    {box, From} when is_pid(From) ->
      From ! Box,
      loop(Fun, LoopData, Data#pdata{box = []});
    {loopdata, Key, From} when is_pid(From) ->
      Result = Fun({loopdata, Key}, LoopData),
      From ! Result,
      loop(Fun, LoopData, Data);
    Msg ->
      ND = Fun({msg, Msg}, LoopData),
      loop(Fun, ND, Data)
  end.

%%%
%%% unit test
%%%

start_test() ->
  P1 = start(),
  P2 = start(),
  ?assert(is_pid(P1)),
  ?assert(is_pid(P2)),
  ?assertNot(P1 =:= P2),
  ?assertNot(erlang:is_process_alive(P1)),
  ?assert(erlang:is_process_alive(P2)).

kill_game_test() ->
  schema:init(),
  Limit = #limit{min = 100, max = 400, small = 5, big = 10},
  game:start(#tab_game_config{module = game, mods = [{wait_players, []}], limit = Limit, seat_count = 9, start_delay = 3000, required = 2, timeout = 1000, max = 2}),

  ?assert(is_pid(where_game(1))),
  ?assert(is_pid(where_game(2))),
  ?assertNot(is_pid(where_game(3))),

  kill_games(),

  ?assertNot(is_pid(where_game(1))),
  ?assertNot(is_pid(where_game(2))),
  ?assertNot(is_pid(where_game(3))).

players_test() ->
  ?assertEqual(2, length(players())),
  ?assertMatch(#tab_player_info{identity = "jack"}, player(jack)),
  ?assertMatch(#tab_player_info{identity = "tommy"}, player(tommy)).
