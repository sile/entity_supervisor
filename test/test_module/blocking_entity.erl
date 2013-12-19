%% @copyright 2013 Takeru Ohta <phjgt308@gmail.com>
%%
%% @doc テスト用に`exit'メッセージをブロックするエンティティプロセス
-module(blocking_entity).

%%--------------------------------------------------------------------------------
%% Exported API
%%--------------------------------------------------------------------------------
-export([start_link/0]).

%%--------------------------------------------------------------------------------
%% Exported Functions
%%--------------------------------------------------------------------------------
-spec start_link() -> {ok, pid()}.
start_link() ->
    {ok, spawn_link(fun () -> process_flag(trap_exit, true), timer:sleep(infinity) end)}.
