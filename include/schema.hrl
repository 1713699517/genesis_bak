-record(tab_agent, {
    aid,
    identity,
    password,
    root = false,
    disable = false,
    parent = root,
    subordinate = [],
    cash = 0,
    credit = 0
  }).

-record(tab_player_info, {
    pid,
    identity,
    password,
    nick,
    photo,
    login_errors = 0,
    disabled = false,
    agent = "root",
    cash = 0,
    credit = 0
  }).

-record(tab_inplay, {
    pid,
    inplay
  }).

-record(tab_charge_log, {
    id = now(),
    aid,
    target,   %% {player|agent, id}
    cash,     %% charge cash
    credit,   %% charge credit
    r_cash,   %% result cash
    r_credit, %% result credit
    b_cash,   %% balance cash
    b_credit, %% balance credit
    date = date(),     %% {year, month, day}
    time = time()      %% {hour, min, sec}
  }).

-record(tab_turnover_log, {
    id = now(),
    aid,      %% aid
    pid,      %% pid
    game,     %% {gid, sn}
    amt,      %% amt
    cost,     %% winner cost amt
    inplay,   %% in out result inplay
    date = date(),     %% {year, month, day}
    time = time()      %% {hour, min, sec}
  }).

-record(tab_buyin_log, {
    id = now(), 
    aid,      %% aid
    pid,      %% pid
    gid,      %% gid
    amt,      %% amt
    cash,     %% cash result by change amt
    credit,   %% credit
    date = date(),     %% {year, month, day}
    time = time()      %% {hour, min, sec}
  }).

-record(tab_counter, {
    type,
    value
  }).

-record(tab_player, {
    pid                 ::integer(),
    process = undefined ::pid() | undefined,
    socket = undefined  ::pid() | undefined 
  }).


-record(tab_game_config, {
    id,
    module,
    mods,
    limit,
    seat_count,
    start_delay,
    required,
    timeout,
    max
  }).

-record(tab_game_xref, {
    gid,
    process,
    module,
    limit,
    seat_count,
    timeout,
    required % min player count 
  }).

-record(tab_cluster_config, {
    id,
    gateways = [],
    mnesia_masters = [],
    logdir = "/tmp",
    max_login_errors = 5,
    %% players can start games
    enable_dynamic_games = false,
    test_game_pass
  }).
