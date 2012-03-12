-module(game).
-behaviour(exch).

-export([id/0, init/2, stop/1, dispatch/2, call/2]).
-export([start/0, start/1, start/2]).

-export([ctx/1]).

-export([watch/2, unwatch/2, join/2, leave/2, bet/2, reward/3, query_seats/1, info/1, list/0]).
-export([raise/2, fold/2]).
-export([broadcast/2, broadcast/3]).

-include("common.hrl").
-include("schema.hrl").
-include("game.hrl").
-include("protocol.hrl").

%%%
%%% callback
%%% 

id() ->
  counter:bump(game).

init(GID, R = #tab_game_config{}) ->
  create_runtime(GID, R),
  #texas { 
    gid = GID, 
    seats = seat:new(R#tab_game_config.seat_count),
    max_joined = R#tab_game_config.seat_count,
    limit = R#tab_game_config.limit,
    timeout = ?PLAYER_TIMEOUT,
    start_delay = R#tab_game_config.start_delay,
    required = R#tab_game_config.required,
    xref = gb_trees:empty(),
    pot = pot:new(),
    deck = deck:new(),
    b = ?UNDEF,
    sb = ?UNDEF,
    bb = ?UNDEF
  }.

stop(#texas{gid = GID, timer = Timer}) ->
  catch erlang:cancel_timer(Timer),
  clear_runtime(GID).

call({watch, {Identity, Process}}, Ctx = #texas{observers = Obs}) ->
  R = #notify_game_detail{
    game = Ctx#texas.gid, 
    pot = pot:total(Ctx#texas.pot),
    stage = Ctx#texas.stage,
    limit = Ctx#texas.limit,
    seats = seat:info(size, Ctx#texas.seats),
    require = Ctx#texas.required,
    joined = Ctx#texas.joined
  },

  player:notify(Process, R),

  %% update observer player process
  case proplists:lookup(Identity, Obs) of
    none ->
      {ok, ok, Ctx#texas{observers = [{Identity, Process}|Obs]}};
    {Identity, Process} ->
      NewObs = [{Identity, Process}] ++ proplists:delete(Identity, Obs),
      {ok, ok, Ctx#texas{observers = NewObs}}
  end;

call({unwatch, {Identity, _Process}}, Ctx = #texas{observers = Obs}) ->
  case proplists:lookup(Identity, Obs) of
    none ->
      {ok, ok, Ctx};
    {Identity, _Proc} ->
      {ok, ok, Ctx#texas{observers = proplists:delete(Identity, Obs)}}
  end;

call(info, Ctx = #texas{gid = GId, joined = Joined, required = Required, seats = Seats, limit = Limit}) ->
  {ok, #notify_game{
      game = GId,
      name = <<"TEXAS_TABLE">>,
      limit = Limit,
      seats = seat:info(size, Seats),
      require = Required,
      joined = Joined
    }, Ctx};

call(pdata, Ctx) ->
  {ok, Ctx, Ctx}.

dispatch({join, _Process, _R}, Ctx = #texas{max_joined = Max, joined = Joined}) when Max =:= Joined ->
  Ctx;

dispatch({join, Process, R = #cmd_join{sn = SN}}, Ctx = #texas{seats = Seats}) when SN /= 0 ->
  case seat:get(SN, Seats) of
    Seat = #seat{state = ?PS_EMPTY} ->
      dispatch({join, Process, Seat, R}, Ctx);
    _ ->
      dispatch({join, Process, R#cmd_join{sn = 0}}, Ctx)
  end;

dispatch({join, Process, R = #cmd_join{sn = SN}}, Ctx = #texas{seats = Seats}) when SN =:= 0 ->
  %% auto compute player seat number
  [H = #seat{}|_] = seat:lookup(?PS_EMPTY, Seats),
  dispatch({join, Process, H, R}, Ctx);
  
dispatch({join, Process, S = #seat{}, R = #cmd_join{identity = Identity}}, Ctx = #texas{observers = Obs, seats = Seats}) ->
  case proplists:lookup(Identity, Obs) of
    {Identity, Process} ->
      JoinedSeats = seat:set(S#seat{
          identity = Identity,
          pid = R#cmd_join.pid,
          process = Process,
          %agent = R#cmd_join.agent,
          hand = [],
          bet = 0,
          inplay = R#cmd_join.buyin,
          state = ?PS_WAIT,
          nick = R#cmd_join.nick,
          photo = R#cmd_join.photo
        }, Seats),

      JoinMsg = #notify_join{
        game = Ctx#texas.gid,
        player = R#cmd_join.pid,
        sn = S#seat.sn,
        buyin = R#cmd_join.buyin,
        nick = R#cmd_join.nick,
        photo = R#cmd_join.photo,
        proc = self()
      },

      Fun = fun() ->
          [] = mnesia:read(tab_inplay, R#cmd_join.pid), % check none inplay record
          [Info] = mnesia:read(tab_player_info, R#cmd_join.pid, write),
          Balance = Info#tab_player_info.cash + Info#tab_player_info.credit,

          case Balance < R#cmd_join.buyin of
            true ->
              exit(err_join_less_balance);
            _ ->
              ok
          end,

          ok = mnesia:write(#tab_buyin_log{
              aid = R#cmd_join.agent, pid = R#cmd_join.pid, gid = Ctx#texas.gid, 
              amt = 0 - R#cmd_join.buyin, cash = Info#tab_player_info.cash - R#cmd_join.buyin,
              credit = Info#tab_player_info.credit}),
          ok = mnesia:write(#tab_inplay{pid = R#cmd_join.pid, inplay = R#cmd_join.buyin}),
          ok = mnesia:write(Info#tab_player_info{cash = Info#tab_player_info.cash - R#cmd_join.buyin})
      end,

      case mnesia:transaction(Fun) of
        {atomic, ok} ->
          broadcast(JoinMsg, Ctx),
          Ctx#texas{seats = JoinedSeats, joined = Ctx#texas.joined + 1};
        {aborted, Err} ->
          ?LOG([{game, error}, {join, R}, {ctx, Ctx}, {error, Err}]),
          Ctx
      end;
    _ -> % not find watch in observers
      ?LOG([{game, error}, {join, R}, {ctx, Ctx}, {error, not_find_observer}]),
      Ctx
  end;

dispatch({leave, _Process, R = #cmd_leave{sn = SN, pid = PId}}, Ctx = #texas{seats = Seats}) ->
  case seat:get(SN, Seats) of
    #seat{pid = PId} ->
      Fun = fun() -> 
          [Info] = mnesia:read(tab_player_info, PId, write),
          [Inplay] = mnesia:read(tab_inplay, PId, write),

          case Inplay#tab_inplay.inplay < 0 of
            true ->
              exit(err_inplay_less_zero);
            _ ->
              ok
          end,

          ok = mnesia:delete_object(Inplay),
          ok = mnesia:write(#tab_buyin_log{
              aid = R#cmd_leave.agent, pid = R#cmd_leave.pid, gid = Ctx#texas.gid, 
              amt = Inplay#tab_inplay.inplay, cash = Info#tab_player_info.cash + Inplay#tab_inplay.inplay,
              credit = Info#tab_player_info.credit}),
          ok = mnesia:write(Info#tab_player_info{cash = Info#tab_player_info.cash + Inplay#tab_inplay.inplay})
      end,

      case mnesia:transaction(Fun) of
        {atomic, ok} ->
          LeaveMsg = #notify_leave{
            sn = SN,
            game = Ctx#texas.gid,
            player = R#cmd_leave.pid,
            proc = self()
          },

          broadcast(LeaveMsg, Ctx),
          LeavedSeats = seat:set(SN, ?PS_LEAVE, Seats),
          Ctx#texas{seats = LeavedSeats, joined = Ctx#texas.joined - 1};
        {aborted, Err} ->
          ?LOG([{game, error}, {leave, R}, {ctx, Ctx}, {error, Err}]),
          Ctx
      end;
    _ ->
      ?LOG([{game, error}, {leave, R}, {ctx, Ctx}, {error, not_find_player}]),
      Ctx
  end;

dispatch({query_seats, Player}, Ctx) when is_pid(Player)->
  Fun = fun(R) ->
      R1 = #notify_seat{
        game = Ctx#texas.gid,
        sn = R#seat.sn,
        state = R#seat.state,
        player = R#seat.pid,
        inplay = R#seat.inplay,
        bet = R#seat.bet,
        nick = R#seat.nick,
        photo = R#seat.photo
      },

      player:notify(Player, R1)
  end,
  lists:map(Fun, seat:get(Ctx#texas.seats)),
  Ctx;

dispatch(_, Ctx) ->
  Ctx.

%%%
%%% client
%%%

start() ->
  Fun = fun(R = #tab_game_config{max = Max}, _Acc) ->
      start(R, Max)
  end, 

  ok = mnesia:wait_for_tables([tab_game_config], ?WAIT_TABLE),
  {atomic, _Result} = mnesia:transaction(fun() -> mnesia:foldl(Fun, nil, tab_game_config) end).

start(Mods) when is_list(Mods)->
  Conf = #tab_game_config{id = 1, module = game, mods = Mods, limit = no_limit, seat_count = 9, start_delay = 3000, required = 2, timeout = 1000, max = 1},
  start(Conf, 1);

start(Conf = #tab_game_config{max = Max}) ->
  start(Conf, Max).

start(_Conf, 0) -> ok;
start(Conf = #tab_game_config{module = Module, mods = Mods}, N) when is_list(Mods) ->
  exch:start(Module, Conf, Mods),
  start(Conf, N - 1);
start(Conf = #tab_game_config{}, N) ->
  start(Conf#tab_game_config{mods = default_mods()}, N).

%% check
bet({R = #seat{}, Amt}, Ctx = #texas{}) ->
  bet({R, Amt, 0}, Ctx);

bet({#seat{sn = SN}, _Call = 0, _Raise = 0}, Ctx = #texas{seats = Seats}) ->
  NewSeats = seat:set(SN, ?PS_BET, Seats),
  Ctx#texas{seats = NewSeats};

%% call & raise
bet({S = #seat{inplay = Inplay, bet = Bet, pid = PId}, Call, Raise}, Ctx = #texas{seats = Seats}) ->
  Amt = Call + Raise,
  {State, AllIn, CostAmt} = case Amt < Inplay of 
    true -> {?PS_BET, false, Amt}; 
    _ -> {?PS_ALL_IN, true, Inplay} 
  end,

  Fun = fun() ->
      [R] = mnesia:read(tab_inplay, PId, write),
      ok = mnesia:write(R#tab_inplay{inplay = Inplay - CostAmt}),
      ok = mnesia:write(#tab_turnover_log{
          aid = S#seat.agent, pid = PId, game = Ctx#texas.gid,
          amt = CostAmt, inplay = Inplay - CostAmt})
  end,
  
  case mnesia:transaction(Fun) of
    {atomic, ok} ->
      NewSeats = seat:set(S#seat{inplay = Inplay - CostAmt, state = State, bet = Bet + CostAmt}, Seats),
      NewPot = pot:add(Ctx#texas.pot, PId, Amt, AllIn),
      Ctx#texas{seats = NewSeats, pot = NewPot}
  end.

reward(#hand{seat_sn = SN, pid = PId}, Amt, Ctx = #texas{seats = S}) when Amt > 0 ->
  NewInplay = mnesia:dirty_update_counter(tab_inplay, PId, Amt),
  Seat = seat:get(SN, S),
  RewardedSeats = seat:set(Seat#seat{inplay = NewInplay}, S),
  Ctx#texas{seats = RewardedSeats}.

broadcast(Msg, #texas{observers = Obs}, []) ->
  broadcast(Msg, Obs);
broadcast(Msg, Ctx = #texas{observers = Obs}, _Exclude = [H|T]) ->
  broadcast(Msg, Ctx#texas{observers = proplists:delete(H, Obs)}, T).

broadcast(Msg, #texas{observers = Obs}) -> 
  broadcast(Msg, Obs);
broadcast(_Msg, []) -> ok;
broadcast(Msg, [{_, Process}|T]) ->
  player:notify(Process, Msg),
  broadcast(Msg, T).

info(Game) when is_pid(Game) ->
  gen_server:call(Game, info).

list() ->
  Fun = fun(#tab_game_xref{process = Game}, Acc) ->
      [info(Game) | Acc]
  end,
  {atomic, Result} = mnesia:transaction(fun() -> mnesia:foldl(Fun, [], tab_game_xref) end),
  Result.

watch(Game, Identity) when is_pid(Game), is_list(Identity) ->
  gen_server:call(Game, {watch, {Identity, self()}}).

unwatch(Game, Identity) when is_pid(Game), is_list(Identity) ->
  gen_server:call(Game, {unwatch, {Identity, self()}}).

join(Game, R = #cmd_join{}) when is_pid(Game) ->
  gen_server:cast(Game, {join, self(), R}).

leave(Game, R = #cmd_leave{}) when is_pid(Game) ->
  gen_server:cast(Game, {leave, self(), R}).

raise(Game, R = #cmd_raise{}) when is_pid(Game) ->
  gen_server:cast(Game, R).

fold(Game, R = #cmd_fold{}) when is_pid(Game) ->
  gen_server:cast(Game, R).

query_seats(Game) when is_pid(Game) ->
  gen_server:cast(Game, {query_seats, self()}).

ctx(Id) ->
  gen_server:call(?LOOKUP_GAME(Id), ctx).

%%%
%%% private
%%%

create_runtime(GID, R) ->
  mnesia:dirty_write(#tab_game_xref {
      gid = GID,
      process = self(),
      module = R#tab_game_config.module,
      limit = R#tab_game_config.limit,
      seat_count = R#tab_game_config.seat_count,
      timeout = R#tab_game_config.timeout,
      required = R#tab_game_config.required
  }).

clear_runtime(GID) ->
  ok = mnesia:dirty_delete(tab_game_xref, GID).

default_mods() ->
  [
    {wait_players, []},
    %% blind rules
    {blinds, []},
    %% deal 2 cards to each player
    {deal_cards, [2, private]}, 
    {ranking, []}, 
    %% start after BB, 3 raises
    {betting, [?GS_PREFLOP]}, 
    %% show 3 shared cards
    {deal_cards, [3, shared]}, 
    {ranking, []}, 
    %% flop
    {betting, [?GS_FLOP]}, 
    %% show 1 more shared card
    {deal_cards, [1, shared]}, 
    {ranking, []}, 
    %% turn
    {betting, [?GS_TURN]}, 
    %% show 1 more shared card
    {deal_cards, [1, shared]}, 
    {ranking, []}, 
    %% river
    {betting, [?GS_RIVER]}, 
    %% showdown
    {showdown, []},
    {restart, []}
  ].

%%%
%%% unit test
%%%

-include_lib("eunit/include/eunit.hrl").

start_test() ->
  setup(),
  game:start([{wait_players, []}, {restart, []}]),
  ?assert(is_pid(?LOOKUP_GAME(1))).

id_test() ->
  setup(),
  ?assertEqual(1, game:id()),
  ?assertEqual(2, game:id()),
  ?assertEqual(3, game:id()).

list_test() ->
  setup(),
  Conf = #tab_game_config{module = game, mods = [{wait_players, []}], limit = no_limit, seat_count = 9, start_delay = 3000, required = 2, timeout = 1000, max = 2},
  game:start(Conf),
  ?assert(is_pid(?LOOKUP_GAME(1))),
  ?assert(is_pid(?LOOKUP_GAME(2))),
  timer:sleep(1000),

  [#notify_game{}|[#notify_game{}|[]]] = game:list().

info_test() ->
  setup(),
  Conf = #tab_game_config{module = game, mods = [{wait_players, []}], limit = no_limit, seat_count = 5, start_delay = 3000, required = 3, timeout = 1000, max = 1},
  game:start(Conf),
  ?assert(is_pid(?LOOKUP_GAME(1))),
  #notify_game{require = R, seats = C} = game:info(?LOOKUP_GAME(1)),
  ?assertEqual(3, R),
  ?assertEqual(5, C).

game_query_test() ->
  ?assert(is_list(protocol:write(#cmd_query_game{}))).

game_info_test() ->
  ?assert(is_list(protocol:write(#notify_game{
      game = 1,
      name = <<"TEXAS_TABLE">>,
      limit = #limit{min = 10, max = 400, small = 5, big = 10},
      seats = 5,
      require = 2,
      joined = 1}
    ))).

setup() ->
  catch mnesia:transaction(fun() ->
        mnesia:foldl(fun(#tab_game_xref{process = Game}, _Acc) ->
              gen_server:call(Game, kill)
          end, [], tab_game_xref)
    end
  ),
  schema:uninstall(),
  schema:install(),
  schema:load_default_data().
