%% @copyright 2013 Takeru Ohta <phjgt308@gmail.com>
%%
%% @doc 何もしないエンティティプロセスを生成／監視するためのテスト用スーパバイザ
-module(do_nothing_entity_supervisor).

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
    {ok, {{do_nothing_entity, start_link, []}, temporary, Shutdown}}.
