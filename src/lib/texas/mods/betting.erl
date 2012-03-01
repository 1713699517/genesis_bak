-module(betting).
-export([start/2, betting/2]).

-include("common.hrl").
-include("game.hrl").
-include("protocol.hrl").

%%%
%%% callback
%%%

start([?GS_PREFLOP], Ctx = #texas{bb = At, bb_amt = C}) -> 
  ask(At, Ctx#texas{stage = ?GS_PREFLOP, call = C});
start([Stage], Ctx = #texas{b = At}) -> 
  ask(At, Ctx#texas{stage = Stage, call = 0}).

% not expectation seat player
betting(#raise{ player = P}, Ctx = #texas{exp_seat = Exp}) when Exp#seat.pid /= P -> 
  {continue, Ctx};

% betting timeout
betting({timeout, _, ?MODULE}, Ctx = #texas{exp_seat = Exp}) ->
  NotTimerCtx = cancel_timer(Ctx),
  betting(#fold{ player = Exp#seat.pid }, NotTimerCtx);

%%%
%%% raise invalid case
%%%

betting(#raise{ player = P, raise = R }, Ctx) when R < 0 -> 
  ?LOG([{betting, raise_error}, {raise, R}]),
  betting(#fold{ player = P }, Ctx);
betting(#raise{ player = P, raise = R}, Ctx = #texas{exp_amt = Amt, exp_seat = Exp})
when (R + Amt) > Exp#seat.inplay; R < Ctx#texas.exp_min; R > Ctx#texas.exp_max -> 
  ?LOG([{betting, raise_error}, {raise, R}, {exp_amt, Amt}, {exp_min, Ctx#texas.exp_min}, {exp_max, Ctx#texas.exp_max}]),
  betting(#fold{ player = P }, Ctx);
betting(#raise{ player = P }, Ctx = #texas{exp_seat = Exp})
when Exp#seat.inplay =< 0 -> 
  ?LOG([{betting, raise_error}, {inplay, Exp#seat.inplay}]),
  betting(#fold{ player = P }, Ctx);

%%%
%%% raise normal case
%%%

betting(#raise{ raise = 0 }, Ctx = #texas{exp_seat = Exp, exp_amt = 0}) ->        % check
  CheckedCtx = game:bet({Exp, 0}, Ctx),
  next_turn(Exp, CheckedCtx);
betting(#raise{ raise = 0 }, Ctx = #texas{exp_seat = Exp, exp_amt = Amt})         % poor all_in
when Exp#seat.inplay < Amt ->
  PooredCtx = game:bet({Exp, Exp#seat.inplay}, Ctx),
  next_turn(Exp, PooredCtx);
betting(#raise{ raise = 0 }, Ctx = #texas{exp_seat = Exp, exp_amt = Amt}) ->      % call & check
  CalledCtx = game:bet({Exp, Amt}, Ctx),
  next_turn(Exp, CalledCtx);
betting(#raise{ raise = R }, Ctx = #texas{exp_seat = Exp, exp_amt = Amt}) ->      % raise & all_in
  BettedCtx = game:bet({Exp, R + Amt}, Ctx),
  Fun = fun(Seat) when Exp#seat.sn /= Seat#seat.sn ->
      Seat#seat{state = ?PS_PLAY}
  end,
  RecoverSeats = lists:map(Fun, seat:lookup(?PS_BET, BettedCtx#texas.seats)),
  RaisedCtx = BettedCtx#texas{call = R + Amt, seats = RecoverSeats},
  next_turn(Exp, RaisedCtx);

%%%
%%% fold
%%%

betting(#fold{player = P}, Ctx = #texas{exp_seat = Exp}) when Exp#seat.pid /= P ->
  {continue, Ctx};
betting(#fold{}, Ctx = #texas{seats = S, exp_seat = Exp}) ->
  NotTimerCtx = cancel_timer(Ctx),
  FoldCtx = NotTimerCtx#texas{seats = seat:set(Exp#seat.sn, ?PS_FOLD, S)},
  next_turn(Exp, FoldCtx);

% skip
betting(_Msg, Ctx) ->
  {skip, Ctx}.

%%%
%%% private
%%%

ask(At = #seat{}, Ctx = #texas{seats = S}) ->
  ask(seat:lookup(?PS_PLAY, S, At), Ctx);
ask([_H], Ctx = #texas{}) ->
  {stop, Ctx};
ask([H|_], Ctx = #texas{}) ->
  ask_for_bet(H, Ctx).
  
ask_for_bet(H = #seat{inplay = I, sn = SN, bet = B}, Ctx = #texas{gid = Id, call = C, pot = Pot, limit = L, stage = S}) ->
  {Min, Max} = limit:raise(L, pot:total(Pot), I, S),
  game:broadcast(#notify_actor{ game = Id, seat = SN}, Ctx),
  player:notify(H#seat.process, #bet_req{ game = Id, call = (C-B), min = Min, max = Max}),

  TimerCtx = start_timer(Ctx),
  ExpCtx = TimerCtx#texas{ exp_seat = H, exp_amt = C-B, exp_min = Min, exp_max = Max },

  {next, betting, ExpCtx}.

next_turn(At = #seat{}, Ctx = #texas{seats = S}) ->
  Active = seat:lookup(?PS_PLAY, S, At),
  Standing = seat:lookup(?PS_STANDING, S, At),
  next_turn(Standing, Active, Ctx).

next_turn(Standing, _, Ctx) when length(Standing) < 2 -> 
  {goto, showdown, Ctx};
next_turn(_, [], Ctx = #texas{pot = Pot, seats = Seats}) ->
  NewPot = pot:new_stage(Pot),
  Fun = fun(Seat) -> Seat#seat{bet = 0, state = ?PS_PLAY} end,
  ResetSeats = lists:map(Fun, seat:lookup(?PS_BET, Seats)),
  {stop, Ctx#texas{seats = ResetSeats, pot = NewPot}};
next_turn(_, [H|_], Ctx) -> 
  ask_for_bet(H, Ctx).

start_timer(Ctx = #texas{timeout = Timeout}) ->
  Timer = erlang:start_timer(Timeout, self(), ?MODULE),
  Ctx#texas{timer = Timer}.

cancel_timer(Ctx = #texas{timer = T}) ->
  catch erlang:cancel_timer(T),
  Ctx#texas{timer = ?UNDEF}.

%betting(Game, Ctx, #raise{ player = Player, raise = 0.0 }) ->
  %Game1 = g:cancel_timer(Game),

  %N = Ctx#texas.exp_seat,
  %Amt = Ctx#texas.exp_amt,
  %Seat = g:get_seat(Game1, Ctx#texas.exp_seat),
  %Inplay = Seat#seat.inplay,

  %Amt1 = case Amt >= Inplay of
    %true ->
      %Inplay; % ALL-IN
    %_ ->
      %Amt
  %end,

  %%% proper bet
  %Game2 = g:set_state(Game1, Player, ?PS_BET),
  %Game3 = g:add_bet(Game2, Player, Amt1),

  %R1 = #notify_raise{ 
    %game = Game3#game.gid, 
    %player = Seat#seat.pid,
    %raise = 0.0,
    %call = Amt1
  %},
  %Game4 = g:broadcast(Game3, R1),
  %Game5 = g:notify_state(Game4, N),
  %next_turn(Game5, Ctx, Ctx#texas.exp_seat);

%%%% Raise
%betting(Game, Ctx, #raise{ player = Player, raise = Amt }) ->
  %Game1 = g:cancel_timer(Game),
  %Call = Ctx#texas.exp_amt,
  %Min = Ctx#texas.exp_min,
  %Max = Ctx#texas.exp_max,
  %N = Ctx#texas.exp_seat,
  %Seat = g:get_seat(Game, Ctx#texas.exp_seat),
  %Inplay = Seat#seat.inplay,
  %RC = Game1#game.raise_count,

  %if 
    %(Amt > Inplay) or 
    %(Amt > Max) or
    %(Max == 0.0) or % should have sent CALL
    %((Amt < Min) and ((Amt + Call) /= Inplay)) ->
      %betting(Game1, Ctx, #fold{ player = Player });
    %true ->
      %%% proper raise
      %RC1 = if 
        %Call /= 0.0 ->
          %RC + 1;
        %true ->
          %RC
      %end,
      %Game2 = g:add_bet(Game1, Player, Amt + Call),
      %Game3 = g:reset_player_state(Game2, ?PS_BET, ?PS_PLAY),
      %Game4 = if
        %Amt + Call == Inplay ->
          %Game3;
        %true ->
          %g:set_state(Game3, Player, ?PS_BET)
      %end,
      %R1 = #notify_raise{ 
        %game = Game4#game.gid,
        %player = Seat#seat.pid,
        %raise = Amt,
        %call = Call
      %},
      %Game5 = g:broadcast(Game4, R1),
      %Game6 = g:notify_state(Game5, N),
      %Game7 = Game6#game{ raise_count = RC1 },
      %Ctx1 = Ctx#texas{ call = Ctx#texas.call + Amt },
      %next_turn(Game7, Ctx1, Ctx1#texas.exp_seat)
  %end;

%%% Fold

%ask_for_bet(Game, Ctx, N) ->
  %Seat = g:get_seat(Game, N),
  %Player = Seat#seat.player,
  %Inplay = Seat#seat.inplay,
  %Bet = Seat#seat.bet,
  %Stage = Ctx#texas.stage,
  %PotSize = g:pot_size(Game),
  %Call = Ctx#texas.call - Bet,
  %Low = Game#game.low,
  %High = Game#game.high,

  %{Min, Max} = (Game#game.limit):raise(Low, High, PotSize, Inplay, Stage),

  %Game1 = g:request_bet(Game, N, Call, Min, Max),
  %Game2 = g:restart_timer(Game1, Game1#game.timeout),

  %{next, betting, Game2, Ctx#texas{ 
      %exp_player = Player, 
      %exp_seat = N,
      %exp_amt = Call,
      %exp_min = Min,
      %exp_max = Max
    %}
  %}.
