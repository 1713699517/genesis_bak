-module(gc_agent).
-export([start_link/1, stop/0]).
-export([init/1, terminate/2, handle_call/3, handle_cast/2]).
-export([collect/0, detail/1]).
-behavior(gen_server).

-include("common.hrl").

start_link(S = #tab_agent{identity = Id}) ->
  gen_server:start_link({local, ?GC_AGENT_NAME(Id)}, ?MODULE, [S], []).

stop() ->
  gen_server:cast(?MODULE, stop).

%%
%% Callback
%%

init([S = #tab_agent{}]) ->
  ok = gc_db:init_xref(agent, S#tab_agent.aid),
  ok = gc_db:init_xref(player, S#tab_agent.aid),

  WeekTurnover = gc_db:get_turnover(week, S#tab_agent.aid),
  TodayTurnover = gc_db:get_turnover(today, S#tab_agent.aid),

  {ok, #gc_agent{
      balance = S#tab_agent.cash + S#tab_agent.credit,

      cash = S#tab_agent.cash,
      credit = S#tab_agent.credit,

      week_turnover = WeekTurnover,
      today_turnover = TodayTurnover,

      today_collect_turnover = ?UNDEF,
      week_collect_turnover = ?UNDEF
    }}.

terminate(Season, _S) ->
  ok.

%% 通知进程向下级代理进程发送“发送汇总数据”的消息。
%% 此消息从ROOT始发，以递归形式向下级发送。
handle_cast(collect, S) when is_reference(S#gc_agent.clct_t) ->                     
  {noreply, S};
handle_cast(collect, S = #gc_agent{}) ->
  case gen_clct_l(S#gc_agent.id) of
    [] ->
      gen_server:cast(report, self()),
      {noreply, S};
    L ->
      T = erlang:start_timer(?GC_COLLECT_TIME, self(), collect),
      {noreply, S#gc_agent{clct_l = L, clct_t = T}}
  end;

%% 通知进程向上级代理进程发送汇总数据
handle_cast(report, S = #gc_agent{level = L}) when L =:= ?GC_ROOT_LEVEL ->
    {noreply, S};
handle_cast(report, S = #gc_agent{}) ->
    gen_server:cast(#agt{}, S#gc_agent.parent),
    {noreply, S};

%% 接收下级代理进程发送的汇总数据
handle_cast({to_receive, #agt{}}, S) 
  when not is_reference(S#gc_agent.clct_t) ->
    {noreply, S};
handle_cast({to_receive, A = #agt{}}, S = #gc_agent{}) ->
  L = {WL, CL} = update_agt_sum(A, S#gc_agent.clct_l),
  case WL of
    [] ->
      compute_collect_data(S#gc_agent.id),
      gen_server:cast(report, self());
    _ -> ok
  end,
  {noreply, S#gc_agent{clct_l = L}};

handle_cast(stop, _S) ->
  {stop, normal, _S}.

handle_call(detail, _From, S = #gc_agent{}) ->
  Week = S#gc_agent.week_turnover + S#gc_agent.week_collect_turnover,
  Today = S#gc_agent.today_turnover + S#gc_agent.today_collect_turnover,

  Result = [
    {identity, S#gc_agent.identity},
    {credit, S#gc_agent.credit}, {cash, S#gc_agent.cash}, {balance, S#gc_agent.balance}, 
    {today_turnover, Today}, {week_turnover, Week}],

  ?LOG([{test, test}]),

  {reply, Result, S}.

%%%
%%% Client Function
%%%

collect() ->
  gen_server:cast(collect, whereis(gc_root_agent)).

detail(Identity) ->
  Name = "gc_" ++ Identity ++ "_agent",
  gen_server:call(detail, whereis(list_to_existing_atom(Name))).

%%%
%%% Private Function
%%%

gen_clct_l(Id) ->
  {gc_db:get_clct_l(Id), []}.

%%% WL not collect list
%%% CL cllected list
update_agt_sum(Agt = #agt{id = Id}, {WL, CL}) ->
  case lists:keyfind(Id, WL) of
    false ->
      %% TODO log this error
      {WL, CL};
    Reporter ->
      gc_db:update(Agt),
      {lists:keydelete(Id, WL), CL ++ [Reporter]}
  end.

compute_collect_data(Id) ->
  ok.
