-module(seat).
-export([new/1, set/2, lookup/2, lookup/3]).

-include("common.hrl").
-include("game.hrl").

new(N) when N > 0 ->
  list_to_tuple(new(N, [])).

lookup(Mask, Seats, _At = #seat{sn = SN})  
when SN > 0, SN =< size(Seats) ->
  Size = size(Seats),
  lookup(Mask, Seats, Size, SN, Size, []).

lookup(Mask, Seats) ->
  Size = size(Seats),
  lookup(Mask, Seats, Size, Size, Size, []).

set(Seat = #seat{sn = SN}, Seats) ->
  setelement(SN, Seats, Seat).

%%%
%%% private
%%%

new(0, Acc) -> Acc;
new(N, Acc) -> new(N - 1, [#seat{sn = N} | Acc]).

lookup(_Mask, _Seats, 0, _At, _N, _Acc) -> [];
lookup(_Mask, _Seats, _Size, _At, 0, Acc) -> lists:reverse(Acc);
lookup(Mask, Seats, Size, At, N, Acc) ->
  SN = (At rem Size) + 1,
  R = element(SN, Seats),
  NewAcc = case check(R#seat.state, Mask) of
    true ->
      [R|Acc];
    _ ->
      Acc
  end,
  lookup(Mask, Seats, Size, At + 1, N - 1, NewAcc).

check(?PS_EMPTY, ?PS_EMPTY) -> true;
check(_, ?PS_EMPTY) -> false;
check(State, Mask) -> (State band Mask) =:= Mask.

  

%%%
%%% unit test
%%%

-include_lib("eunit/include/eunit.hrl").

new_test() ->
  R = new(4),
  ?assertEqual(4, size(R)),
  First = element(1, R),
  Last = element(4, R),
  ?assertEqual(1, First#seat.sn),
  ?assertEqual(4, Last#seat.sn).

lookup_test() ->
  All = new(5),
  R = seat:lookup(?PS_EMPTY, All),
  ?assertEqual(5, length(R)),
  First = lists:nth(1, R),
  Last = lists:nth(5, R),
  ?assertEqual(1, First#seat.sn),
  ?assertEqual(?PS_EMPTY, First#seat.state),
  ?assertEqual(5, Last#seat.sn),
  ?assertEqual(?PS_EMPTY, Last#seat.state).

lookup_at_test() ->
  All = new(5),
  S = element(3, All),
  R = seat:lookup(?PS_EMPTY, All, S),
  ?assertEqual(5, length(R)),
  First = lists:nth(1, R),
  Last = lists:nth(5, R),
  ?assertEqual(4, First#seat.sn),
  ?assertEqual(3, Last#seat.sn).

lookup_mask_test() ->
  S = #seat{sn = 3, state = ?PS_PLAY},
  R = seat:lookup(?PS_EMPTY, seat:set(S, new(5))),
  ?assertEqual(4, length(R)),
  ?assertEqual(4, (lists:nth(3, R))#seat.sn).
