%% @copyright 2013 Takeru Ohta <phjgt308@gmail.com>
%%
%% @doc `exit'メッセージをブロックするエンティティプロセスを生成／監視するためのテスト用スーパバイザ
-module(blocking_entity_supervisor).

-behaviour(entity_supervisor).

%%--------------------------------------------------------------------------------
%% 'entity_supervisor' Callback API
%%--------------------------------------------------------------------------------
-export([init/1]).

%%--------------------------------------------------------------------------------
%% 'entity_supervisor' Callback Functions
%%--------------------------------------------------------------------------------
%% @hidden
init([Shutdown]) ->
    {ok, {{blocking_entity, start_link, []}, temporary, Shutdown}}.
