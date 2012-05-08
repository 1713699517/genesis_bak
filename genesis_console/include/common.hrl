-include_lib("genesis/include/common.hrl").
-include_lib("genesis/include/schema.hrl").
-include("gc_agent.hrl").

-define(GC_AGENT_NAME(Identity), erlang:list_to_atom("gc_" ++ Identity ++ "_agent")).
-define(GC_COLLECT_TIME, 1000 * 60).
-define(GC_ROOT_LEVEL, 0).

-ifdef(TEST).
-define(SPAWN_TEST(Tests), {spawn, {setup, fun setup/0, fun cleanup/1, Tests}}).
-define(SLEEP, timer:sleep(500)).
-endif.
