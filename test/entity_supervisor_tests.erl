%% @copyright 2013 Takeru Ohta <phjgt308@gmail.com>
-module(entity_supervisor_tests).

-include_lib("eunit/include/eunit.hrl").

start_link_test_() ->
    [
     {"名前無しスーパバイザを起動",
      fun () ->
              Result = entity_supervisor:start_link(do_nothing_entity_supervisor, [infinity]),
              ?assertMatch({ok, _}, Result),
              {ok, Pid} = Result,
              ?assertEqual(ok, exit_and_wait(Pid, shutdown, 100))
      end},
     {"名前付きスーパバイザを起動",
      fun () ->
              Result = entity_supervisor:start_link({local, do_nothing_sup}, do_nothing_entity_supervisor, [infinity]),
              ?assertMatch({ok, _}, Result),
              {ok, Pid} = Result,
              ?assertEqual(Pid, whereis(do_nothing_sup)),
              ?assertEqual(ok, exit_and_wait(Pid, shutdown, 100))
      end}
    ].

create_entity_test_() ->
    [
     {"エンティティを作成",
      fun () ->
              {ok, SupPid} = entity_supervisor:start_link(do_nothing_entity_supervisor, [infinity]),

              EntityId = <<"entity 1">>,
              
              Result = entity_supervisor:create_entity(SupPid, EntityId, [], []),
              ?assertMatch({ok, _}, Result),
              {ok, EntityPid} = Result,

              %% 同じIDのエンティティは作成できない
              ?assertEqual({error, {already_exists, EntityPid}}, entity_supervisor:create_entity(SupPid, EntityId, [], [])),

              %% 別のIDなら問題ない
              ?assertMatch({ok, _}, entity_supervisor:create_entity(SupPid, <<"entity 2">>, [], [])),

              ?assertEqual(ok, exit_and_wait(SupPid, shutdown, 100)),

              %% スーパバイザ停止時に、エンティティも解放される
              ?assertEqual(false, is_process_alive(EntityPid))
      end},
     {"属性付きのエンティティを作成",
      fun () ->
              {ok, SupPid} = entity_supervisor:start_link(do_nothing_entity_supervisor, [infinity]),

              EntityId   = <<"entity 1">>,
              Attributes = [{attr1, 1}, {attr2, 2}],
              
              Result = entity_supervisor:create_entity(SupPid, EntityId, Attributes, []),
              ?assertMatch({ok, _}, Result),
              {ok, EntityPid} = Result,

              %% 属性は重複が許容される
              ?assertMatch({ok, _}, entity_supervisor:create_entity(SupPid, <<"entity 2">>, Attributes, [])),

              ?assertEqual(ok, exit_and_wait(SupPid, shutdown, 100)),

              %% スーパバイザ停止時に、エンティティも解放される
              ?assertEqual(false, is_process_alive(EntityPid))
      end},
     {"特定のエンティティ作成がブロックしている場合でも、IDが異なるエンティティの作成には影響を与えない",
      fun () ->
              {ok, SupPid} = entity_supervisor:start_link(slow_init_entity_supervisor, []),

              Parent = self(),
              
              %% ブロック
              EntityId1 = <<"entity1">>,
              Pid1 = spawn(fun () ->
                                   Result = entity_supervisor:create_entity(SupPid, EntityId1, [], [[500]]),
                                   Parent ! {result, self(), Result}
                           end),

              %% 同じID
              Pid2 = spawn(fun () ->
                                   Result = entity_supervisor:create_entity(SupPid, EntityId1, [], [[0]]),
                                   Parent ! {result, self(), Result}
                           end),

              %% 別ID
              EntityId2 = <<"entity2">>,
              Pid3 = spawn(fun () ->
                                   Result = entity_supervisor:create_entity(SupPid, EntityId2, [], [[0]]),
                                   Parent ! {result, self(), Result}
                           end),

              receive
                  {result, ResultPid1, Result1} ->    
                      ?assertMatch({ok, _}, Result1),
                      ?assertEqual(Pid3, ResultPid1)  % EntityId2の生成が一番終わるのが早い
                      
              end,
              receive
                  {result, ResultPid2, {ok, EntityPid1}} ->
                      ?assertEqual(Pid1, ResultPid2)
              end,
              receive
                  {result, ResultPid3, Result3} ->
                      ?assertEqual({error, {already_exists, EntityPid1}}, Result3),
                      ?assertEqual(Pid2, ResultPid3)
              end
      end},
     {"特定のエンティティ作成でブロック中のプロセスが死んだ場合は、同じIDに対する次のプロセスに生成権利が引き継がれる",
      fun () ->
              {ok, SupPid} = entity_supervisor:start_link(slow_init_entity_supervisor, []),

              Parent = self(),
              
              %% ブロック
              EntityId1 = <<"entity1">>,
              Pid1 = spawn(fun () ->
                                   Result = entity_supervisor:create_entity(SupPid, EntityId1, [], [[100, wrong_timeout, 500]]),
                                   Parent ! {result, self(), Result}
                           end),

              %% 同じID
              Pid2 = spawn(fun () ->
                                   Result = entity_supervisor:create_entity(SupPid, EntityId1, [], [[0]]),
                                   Parent ! {result, self(), Result}
                           end),
              receive
                  {result, ResultPid1, {ok, _}} -> ?assertEqual(Pid2, ResultPid1)
              end,
              receive
                  {result, ResultPid2, {error, _}} -> ?assertEqual(Pid1, ResultPid2)
              end
      end},
     {"特定のエンティティ作成でブロック中のプロセスが死んで、かつ次のプロセスも死んでいる場合",
      fun () ->
              {ok, SupPid} = entity_supervisor:start_link(slow_init_entity_supervisor, []),

              Parent = self(),
              
              %% ブロック
              EntityId1 = <<"entity1">>,
              Pid1 = spawn(fun () ->
                                   Result = entity_supervisor:create_entity(SupPid, EntityId1, [], [[100, wrong_timeout]]),
                                   Parent ! {result, self(), Result}
                           end),

              %% 同じID
              Pid2 = spawn(fun () ->
                                   Result = entity_supervisor:create_entity(SupPid, EntityId1, [], [[0]], 10),
                                   Parent ! {result, self(), Result}
                           end),
              receive
                  {result, ResultPid1, {error, _}} -> ?assertEqual(Pid2, ResultPid1)
              end,
              receive
                  {result, ResultPid2, {error, _}} -> ?assertEqual(Pid1, ResultPid2)
              end
      end}
    ].

find_entity_test_() ->
    [
     {"作成済みエンティティを検索する (無名スーパバイザ版)",
      fun () ->
              {ok, SupPid} = entity_supervisor:start_link(do_nothing_entity_supervisor, [infinity]),

              EntityIds = [<<"entity 1">>, <<"entity 2">>, <<"entity 3">>],
              ok = lists:foreach(fun (Id) -> ?assertMatch({ok, _}, entity_supervisor:create_entity(SupPid, Id, [], [])) end,
                                 EntityIds),

              ?assertMatch({ok, _}, entity_supervisor:find_entity(SupPid, <<"entity 2">>)),
              ?assertEqual({error, not_found}, entity_supervisor:find_entity(SupPid, entity_2)),
              
              ?assertEqual(ok, exit_and_wait(SupPid, shutdown, 100))
      end},
     {"作成済みエンティティを検索する (名前付きスーパバイザ版)",
      fun () ->
              {ok, _} = entity_supervisor:start_link({local, do_nothing_sup}, do_nothing_entity_supervisor, [infinity]),

              EntityIds = [<<"entity 1">>, <<"entity 2">>, <<"entity 3">>],
              ok = lists:foreach(fun (Id) -> ?assertMatch({ok, _}, entity_supervisor:create_entity(do_nothing_sup, Id, [], [])) end,
                                 EntityIds),

              ?assertMatch({ok, _}, entity_supervisor:find_entity(do_nothing_sup, <<"entity 2">>)),
              ?assertEqual({error, not_found}, entity_supervisor:find_entity(do_nothing_sup, entity_2)),
              
              ?assertEqual(ok, exit_and_wait(whereis(do_nothing_sup), shutdown, 100))
      end}
    ].

find_entity_by_attributes_test_() ->
    [
     {"作成済みエンティティを属性から検索する",
      fun () ->
              {ok, SupPid} = entity_supervisor:start_link(do_nothing_entity_supervisor, [infinity]),

              EntityIds = [{attr_val_a, <<"entity 1">>},  % 1 と 3 の属性値が等しい
                           {attr_val_b, <<"entity 2">>},
                           {attr_val_a, <<"entity 3">>}],
              ok = lists:foreach(fun ({Index, Id}) ->
                                         Attrs = [{attr, Index}] ++ [{common, erlang}],
                                         ?assertMatch({ok, _}, entity_supervisor:create_entity(SupPid, Id, Attrs, []))
                                 end,
                                 EntityIds),

              Result = entity_supervisor:find_entity_by_attributes(SupPid, [{common, erlang}, {attr, attr_val_a}]),
              ?assertMatch({ok, _}, Result),
              {ok, Entities} = Result,

              %% 指定した属性に一致する全てのエンティティが返される
              ?assertEqual(lists:sort([Id || {attr_val_a, Id} <- EntityIds]),
                           lists:sort([Id || {Id, _, _} <- Entities])),

              ?assertEqual(ok, exit_and_wait(SupPid, shutdown, 100))
      end}
    ].

delete_entity_test_() ->
    [
     {"エンティティを削除する",
      fun () ->
              {ok, _} = entity_supervisor:start_link({local, do_nothing_sup}, do_nothing_entity_supervisor, [infinity]),

              EntityIds = [<<"entity 1">>, <<"entity 2">>, <<"entity 3">>],
              ok = lists:foreach(fun (Id) -> ?assertMatch({ok, _}, entity_supervisor:create_entity(do_nothing_sup, Id, [{attr, val}], [])) end,
                                 EntityIds),

              ?assertEqual(ok, entity_supervisor:delete_entity(do_nothing_sup, <<"entity 2">>)),
              timer:sleep(10),  % delete_entity/2 は非同期なのでプロセスが実際に終了するまでしばらく待つ (XXX: タイミング依存のコードは良くない)
              ?assertEqual({error, not_found}, entity_supervisor:find_entity(do_nothing_sup, <<"entity 2">>)),
              
              ?assertEqual(ok, exit_and_wait(whereis(do_nothing_sup), shutdown, 100))              
      end}
     ].

get_entities_test_() ->
    [
     {"エンティティ一覧を取得する: 無名スーパバイザ",
      fun () ->
              {ok, SupPid} = entity_supervisor:start_link(do_nothing_entity_supervisor, [infinity]),

              EntityIds = [<<"entity 1">>, <<"entity 2">>, <<"entity 3">>],
              ok = lists:foreach(fun (Id) -> ?assertMatch({ok, _}, entity_supervisor:create_entity(SupPid, Id, [], [])) end,
                                 EntityIds),

              Result = entity_supervisor:get_entities(SupPid),
              ?assertMatch({ok, _}, Result),
              {ok, Entities} = Result,

              ?assertEqual(lists:sort(EntityIds),
                           lists:sort([Id || {Id, _, _} <- Entities])),
              
              ?assertEqual(ok, exit_and_wait(SupPid, shutdown, 100))              
      end},
     {"エンティティ一覧を取得する: 名前付きスーパバイザ",
      fun () ->
              {ok, _} = entity_supervisor:start_link({local, do_nothing_sup}, do_nothing_entity_supervisor, [infinity]),

              EntityIds = [<<"entity 1">>, <<"entity 2">>, <<"entity 3">>],
              ok = lists:foreach(fun (Id) -> ?assertMatch({ok, _}, entity_supervisor:create_entity(do_nothing_sup, Id, [], [])) end,
                                 EntityIds),

              Result = entity_supervisor:get_entities(do_nothing_sup),
              ?assertMatch({ok, _}, Result),
              {ok, Entities} = Result,

              ?assertEqual(lists:sort(EntityIds),
                           lists:sort([Id || {Id, _, _} <- Entities])),
              
              ?assertEqual(ok, exit_and_wait(whereis(do_nothing_sup), shutdown, 100))              
      end}
    ].

abnormal_case_test_() ->
    [
     {"不明な call/cast/info を受けてもサーバは停止しない",
      fun () ->
              {ok, SupPid} = entity_supervisor:start_link(do_nothing_entity_supervisor, [infinity]),

              catch gen_server:call(SupPid, unknown, 5),
              gen_server:cast(SupPid, unknown),
              SupPid ! unknown,

              ?assertEqual(true, is_process_alive(SupPid)),
              
              ?assertEqual(ok, exit_and_wait(SupPid, shutdown, 100))              
      end},
     {"`Shutdown'指定が`infinity'の場合は、エンティティプロセスが`exit/2'をブロックした場合、エンティティプロセスは永久に終了しない",
      fun () ->
              {ok, SupPid} = entity_supervisor:start_link(blocking_entity_supervisor, [infinity]),

              EntityId = <<"entity 2">>,
              ?assertMatch({ok, _}, entity_supervisor:create_entity(SupPid, EntityId, [], [])),

              ?assertEqual(ok, entity_supervisor:delete_entity(SupPid, EntityId)),
              timer:sleep(100),  % 普通なら終了しているはずであろう時間待つ (XXX: タイミング依存のコードは良くない)
              ?assertMatch({ok, _}, entity_supervisor:find_entity(SupPid, <<"entity 2">>)),

              ?assertEqual(ok, exit_and_wait(SupPid, kill, 100)) % shutdownだと落ちないので、killを送る
      end},
     {"`Shutdown'指定が整数値の場合は、エンティティプロセスが`exit/2'をブロックした場合、指定されたミリ秒以上ブロックされた場合は強制的にkillされる",
      fun () ->
              {ok, SupPid} = entity_supervisor:start_link(blocking_entity_supervisor, [11]),

              EntityId = <<"entity 2">>,
              ?assertMatch({ok, _}, entity_supervisor:create_entity(SupPid, EntityId, [], [])),

              ?assertEqual(ok, entity_supervisor:delete_entity(SupPid, EntityId)),
              timer:sleep(10),
              ?assertMatch({ok, _}, entity_supervisor:find_entity(SupPid, <<"entity 2">>)),              
              timer:sleep(10),
              ?assertEqual({error, not_found}, entity_supervisor:find_entity(SupPid, <<"entity 2">>)),

              ?assertEqual(ok, exit_and_wait(SupPid, kill, 100)) % shutdownだと落ちないので、killを送る
      end},
     {"`Shutdown'指定が`brutal_kill'の場合は、エンティティプロセスが`exit/2'をブロックしても強制的にkillされる",
      fun () ->
              {ok, SupPid} = entity_supervisor:start_link(blocking_entity_supervisor, [brutal_kill]),

              EntityId = <<"entity 2">>,
              ?assertMatch({ok, _}, entity_supervisor:create_entity(SupPid, EntityId, [], [])),

              ?assertEqual(ok, entity_supervisor:delete_entity(SupPid, EntityId)),
              timer:sleep(10),  % delete_entity/2 は非同期なのでプロセスが実際に終了するまでしばらく待つ (XXX: タイミング依存のコードは良くない)
              ?assertEqual({error, not_found}, entity_supervisor:find_entity(SupPid, <<"entity 2">>)),

              ?assertEqual(ok, exit_and_wait(SupPid, shutdown, 100))              
      end}
    ].

%%--------------------------------------------------------------------------------
%% Internal Functions
%%--------------------------------------------------------------------------------
exit_and_wait(Pid, Reason, Timeout) ->
    true = exit(Pid, Reason),
    Old = process_flag(trap_exit, true),
    try
        receive
            {'EXIT', Pid, _Reason} -> ok
        after Timeout ->
                {error, timeout}
        end
    after
        process_flag(trap_exit, Old)
    end.
