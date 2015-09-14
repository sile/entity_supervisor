%% @copyright 2013 Takeru Ohta <phjgt308@gmail.com>
%%
%% @doc Simple Supervisor for Entity Processes
-module(entity_supervisor).

-behaviour(gen_server).
-compile(nowarn_deprecated_type).

%%--------------------------------------------------------------------------------
%% Exported API
%%--------------------------------------------------------------------------------
-export([
         start_link/2,
         start_link/3,
         create_entity/4,
         create_entity/5,
         find_entity/2,
         find_entity_by_attributes/2,
         delete_entity/2, delete_entity/3,
         get_entities/1
        ]).

-export_type([
              manager_name/0,
              manager_ref/0,
              entity/0,
              entity_id/0,
              attribute/0,
              mfargs/0,
              restart/0,
              shutdown/0,
              system_event/0
             ]).

%%--------------------------------------------------------------------------------
%% Behaviour Interface
%%--------------------------------------------------------------------------------
-callback init(Args) -> {ok, EntityCreationSpec} when
      Args               :: term(),
      EntityCreationSpec :: {CreateFunSpec::mfargs(), restart(), shutdown()}.

%% optional callback
%% -callback handle_event(system_event()) -> any().

%%--------------------------------------------------------------------------------
%% 'gen_server' Callback API
%%--------------------------------------------------------------------------------
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%%--------------------------------------------------------------------------------
%% Macros & Records & Types
%%--------------------------------------------------------------------------------
-define(STATE, ?MODULE).

-type my_dict() :: term(). % dict:dict()
-type my_queue() :: term(). % queue:queue()

-record(?STATE,
        {
          module        :: module(),
          create_mfargs :: mfargs(),
          restart       :: restart(),
          shutdown      :: shutdown(),

          id_to_entity             :: ets:tid(), % entity_id() => entity()
          pid_to_id   = dict:new() :: my_dict(),    % pid() => entity_id()
          attr_to_ids = dict:new() :: my_dict(),    % attribute() => set of entity_id()

          reserve_queues = dict:new() :: my_dict(),  % entity_id() => Waitings::queue(From)
          right_holders  = dict:new() :: my_dict()   % pid() => entity_id()
        }).

-type manager_name() :: {local, LocalName::atom()}
                      | {global, GlobalName::term()}
                      | {via, module(), ViaName::term()}.

-type manager_ref() :: atom()
                     | {atom(), node()}
                     | {global, GlobalName::term()}
                     | {via, module(), ViaName::term()}
                     | pid().

-type entity_id() :: term().
-type attribute() :: {Key::term(), Value::term()}.

-type mfargs()   :: {module(), Function::atom(), Args::[term()]}.
-type restart()  :: temporary.
-type shutdown() :: brutal_kill | timeout().

-type entity() :: {entity_id(), pid(), [attribute()]}.

-type system_event() :: {'ENTITY_CREATED', entity()}
                      | {'ENTITY_DELETED', entity(), Reason::term()}.

-type from() :: {pid(), Tag::term()}.

%%--------------------------------------------------------------------------------
%% Exported Functions
%%--------------------------------------------------------------------------------
-spec start_link(module(), [term()]) -> {ok, pid()} | {error, Reason::term()}.
start_link(Module, Args) ->
    gen_server:start_link(?MODULE, [none, Module, Args], []).

-spec start_link(manager_name(), module(), [term()]) -> {ok, pid()} | {error, Reason} when
      Reason :: {already_started, pid()} | term().
start_link(ManagerName, Module, Args) ->
    Name = case ManagerName of
               {local, LocalName} -> {name, LocalName};
               _                  -> none
           end,
    gen_server:start_link(ManagerName, ?MODULE, [Name, Module, Args], []).

-spec create_entity(manager_ref(), entity_id(), [attribute()], [term()], timeout()) -> {ok, pid()} | {error, Reason} when
      Reason :: {already_exists, pid()} | {timeout, manager_ref()} | {noproc, manager_ref()} | term().
create_entity(ManagerRef, EntityId, Attrs, Args, Timeout) ->
    Parent = self(),
    Ref = make_ref(),
    Fun = fun() ->
                  Result =
                      case reserve(ManagerRef, EntityId, Timeout) of
                          {error, Reason} -> {error, Reason};
                          {ok, MFArgs}    ->
                              {Module, Function, DefaultArgs} = MFArgs,
                              case apply(Module, Function, DefaultArgs ++ Args) of
                                  {error, Reason} -> {error, Reason};
                                  {ok, EntityPid} ->
                                      ok = confirm_reservation(ManagerRef, EntityId, EntityPid, Attrs, Timeout),
                                      {ok, EntityPid}
                              end
                      end,
                  Parent ! {Ref, Result}
          end,
    Monitor = monitor(process, spawn(Fun)),
    receive
        {Ref, Result} ->
            _ = demonitor(Monitor, [flush]),
            Result;
        {'DOWN', Monitor, _, Pid, Reason} ->
            {error, {temporary_process_down, Pid, Reason}}
    end.

-spec create_entity(manager_ref(), entity_id(), [attribute()], [term()]) -> {ok, pid()} | {error, Reason} when
      Reason :: {already_exists, pid()} | {timeout, manager_ref()} | {noproc, manager_ref()} | term().
create_entity(ManagerRef, EntityId, Attrs, Args) ->
    create_entity(ManagerRef, EntityId, Attrs, Args, 5000).

-spec find_entity(manager_ref(), entity_id()) -> {ok, entity()} | {error, Reason} when
      Reason :: not_found | {timeout, manager_ref()} | {noproc, manager_ref()} | term().
find_entity(ManagerRef, EntityId) when is_atom(ManagerRef) ->
    case safe_ets_lookup(ManagerRef, EntityId) of
        {ok, []}        -> {error, not_found};
        {ok, [Entity]}  -> {ok, Entity};
        {error, Reason} -> {error, Reason}
    end;
find_entity(ManagerRef, EntityId) ->
    safe_gen_server_call(ManagerRef, {find_entity, EntityId}).

-spec find_entity_by_attributes(manager_ref(), [attribute()]) -> {ok, [entity()]} | {error, Reason} when
      Reason :: {timeout, manager_ref()} | {noproc, manager_ref()} | term().
find_entity_by_attributes(ManagerRef, Attributes) ->
    safe_gen_server_call(ManagerRef, {find_entity_by_attributes, Attributes}).

%% @equiv delete_entity(ManagerRef, EntityId, shutdown)
-spec delete_entity(manager_ref(), entity_id()) -> ok.
delete_entity(ManagerRef, EntityId) ->
    delete_entity(ManagerRef, EntityId, shutdown).

-spec delete_entity(manager_ref(), entity_id(), term()) -> ok.
delete_entity(ManagerRef, EntityId, Reason) ->
    gen_server:cast(ManagerRef, {delete_entity, {EntityId, Reason}}).

-spec get_entities(manager_ref()) -> {ok, [entity()]} | {error, Reason} when
      Reason :: {timeout, manager_ref()} | {noproc, manager_ref()} | term().
get_entities(ManagerRef) when is_atom(ManagerRef) ->
    safe_ets_tab2list(ManagerRef);
get_entities(ManagerRef)->
    safe_gen_server_call(ManagerRef, get_entities).

%%--------------------------------------------------------------------------------
%% 'gen_server' Callback Functions
%%--------------------------------------------------------------------------------
%% @hidden
init([TableName, Module, Args]) ->
    _ = process_flag(trap_exit, true),
    {ok, EntitySpec} = Module:init(Args),
    {MFArgs = {_, _, _}, Restart, Shutdown} = EntitySpec,

    IdToEntity =
        case TableName of
            {name, Name} -> ets:new(Name,         [set, protected, named_table]);
            none         -> ets:new(id_to_entity, [set, protected])
        end,
    State = #?STATE{
                module        = Module,
                create_mfargs = MFArgs,
                restart       = Restart,
                shutdown      = Shutdown,
                id_to_entity  = IdToEntity
               },
    {ok, State}.

%% @hidden
handle_call({reserve, Arg}, From, State0) ->
    State = update_record_layout(State0),
    {Result, State2} = do_reserve(Arg, From, State),
    case Result of
        {ok, MFArgs}    -> {reply, {ok, MFArgs}, State2};
        {error, queued} -> {noreply, State2};
        {error, Reason} -> {reply, {error, Reason}, State2}
    end;
handle_call({confirm_reservation, Arg}, _From, State0) ->
    State = update_record_layout(State0),
    {Result, State2} = do_confirm_reservation(Arg, State),
    {reply, Result, State2};
handle_call({find_entity, Arg}, _From, State) ->
    Result = do_find_entity(Arg, State),
    {reply, Result, State};
handle_call({find_entity_by_attributes, Arg}, _From, State0) ->
    State = update_record_layout(State0),
    Result = do_find_entity_by_attributes(Arg, State),
    {reply, Result, State};
handle_call(get_entities, _From, State0) ->
    State = update_record_layout(State0),
    Result = do_get_entities(State),
    {reply, Result, State};
handle_call(Request, From, State) ->
    ok = error_logger:warning_msg("unknown call: request=~p, from=~p", [Request, From]),
    {noreply, State}.

%% @hidden
handle_cast({delete_entity, Arg}, State0) ->
    State = update_record_layout(State0),
    State2 = do_delete_entity(Arg, State),
    {noreply, State2};
handle_cast(Request, State) ->
    ok = error_logger:warning_msg("unknown cast: request=~p", [Request]),
    {noreply, State}.

%% @hidden
handle_info({exit_timeout, Pid}, State) ->
    true = exit(Pid, kill),
    {noreply, State};
handle_info({'DOWN', _, _, Pid, _}, State0) ->
    State = update_record_layout(State0),
    #?STATE{create_mfargs = MFArgs, reserve_queues = Queues, right_holders = Holders} = State,
    case dict:find(Pid, Holders) of
        error          -> {noreply, State};   % Queuesの中に入っているプロセスのダウンはここでは無視して、後でis_process_alive/1でチェックする
        {ok, EntityId} ->
            Queue = dict:fetch(EntityId, Queues),
            case take_first_alive_waiter(Queue) of
                empty ->
                    Holders2 = dict:erase(Pid, Holders),
                    Queues2  = dict:erase(EntityId, Queues),
                    State2 = State#?STATE{right_holders = Holders2, reserve_queues = Queues2},
                    {noreply, State2};
                {{WaiterPid, _} = From, Queue2} ->
                    _ = gen_server:reply(From, {ok, MFArgs}),
                    Holders2 = dict:store(WaiterPid, EntityId, Holders),
                    Queues2  = dict:store(EntityId, Queue2, Queues),
                    State2 = State#?STATE{right_holders = Holders2, reserve_queues = Queues2},
                    {noreply, State2}
            end
    end;
handle_info({'EXIT', Pid, Reason}, State0) ->
    State = update_record_layout(State0),
    #?STATE{pid_to_id = PidToId, id_to_entity = IdToEntity, module = Module} = State,
    case dict:find(Pid, PidToId) of
        error ->
            ok = error_logger:warning_msg("unknown 'EXIT' message: pid=~p, reason=~p", [Pid, Reason]),
            {noreply, State};
        {ok,  Id} ->
            [Entity] = ets:lookup(IdToEntity, Id),
            ok = handle_event_if_exported(Module, {'ENTITY_DELETED', Entity, Reason}),
            {noreply, delete_entity_entry(Entity, State)}
    end;
handle_info(Info, State) ->
    ok = error_logger:warning_msg("unknown info: info=~p", [Info]),
    {noreply, State}.

%% @hidden
terminate(Reason, State0) ->
    State = update_record_layout(State0),
    #?STATE{id_to_entity = IdToEntity} = State,
    ok = exit_all_entity(Reason, State),
    true = ets:delete(IdToEntity),
    ok.

%% @hidden
code_change(_OldVsn, State, _Extra) ->
    {ok, update_record_layout(State)}.

%%--------------------------------------------------------------------------------
%% Internal Functions
%%--------------------------------------------------------------------------------
-spec update_record_layout(tuple()) -> #?STATE{}.
update_record_layout(Old) when not is_record(Old, ?STATE) ->
    NewSize = record_info(size, ?STATE),
    OldSize = tuple_size(Old),
    Olds = tuple_to_list(#?STATE{}),
    case OldSize > NewSize of
        true  -> list_to_tuple(lists:sublist(Olds, 1, NewSize));
        false ->
            Defaults = lists:nthtail(OldSize, tuple_to_list(#?STATE{})),
            list_to_tuple(Olds ++ Defaults)
    end;
update_record_layout(State) ->
    State.

-spec reserve(manager_ref(), entity_id(), timeout()) -> {ok, mfargs()} | {error, Reason} when
      Reason :: {timeout, manager_ref()} | {noproc, manager_ref()} | {already_exists, pid()} | term().
reserve(ManagerRef, EntityId, Timeout) ->
    safe_gen_server_call(ManagerRef, {reserve, {self(), EntityId}}, Timeout).

-spec confirm_reservation(manager_ref(), entity_id(), pid(), [attribute()], timeout()) -> ok.
confirm_reservation(ManagerRef, EntityId, EntityPid, Attributes, Timeout) ->
    ok = safe_gen_server_call(ManagerRef, {confirm_reservation, {self(), {EntityId, EntityPid, Attributes}}}, Timeout),
    true = unlink(EntityPid),
    ok.

-spec do_reserve({Requester::pid(), entity_id()}, From::term(), #?STATE{}) -> {Result, #?STATE{}} when
      Result :: {ok, mfargs()} | {error, Reason},
      Reason :: {already_exists, pid()} | queued | term().
do_reserve({Requester, Id}, From, State) ->
    #?STATE{create_mfargs = MFArgs, id_to_entity = IdToEntity, reserve_queues = Queues} = State,
    case ets:lookup(IdToEntity, Id) of
        [{_, Pid, _}] -> {{error, {already_exists, Pid}}, State};
        []            ->
            _ = monitor(process, Requester),
            case dict:find(Id, Queues) of
                error ->
                    Queues2  = dict:store(Id, queue:new(), Queues),
                    Holders2 = dict:store(Requester, Id, State#?STATE.right_holders),
                    {{ok, MFArgs}, State#?STATE{reserve_queues = Queues2, right_holders = Holders2}};
                {ok, WaitingQueue} ->
                    Queues2 = dict:store(Id, queue:in(From, WaitingQueue), Queues),
                    {{error, queued}, State#?STATE{reserve_queues = Queues2}}
            end
    end.

-spec do_confirm_reservation({Requester::pid(), entity()}, #?STATE{}) -> {Result, #?STATE{}} when
      Result :: ok | {error, Reason::term()}.
do_confirm_reservation({Requester, Entity}, State) ->
    #?STATE{reserve_queues = Queues, right_holders = Holders} = State,
    {EntityId, EntityPid, _} = Entity,
    true = link(EntityPid),
    ok = handle_event_if_exported(State#?STATE.module, {'ENTITY_CREATED', Entity}),
    State2 = insert_entity_entry(Entity, State),
    ok = lists:foreach(fun (From) -> gen_server:reply(From, {error, {already_exists, EntityPid}}) end,
                       queue:to_list(dict:fetch(EntityId, Queues))),
    Queues2  = dict:erase(EntityId, Queues),
    Holders2 = dict:erase(Requester, Holders),
    {ok, State2#?STATE{reserve_queues = Queues2, right_holders = Holders2}}.

-spec take_first_alive_waiter(my_queue()) -> empty | {from(), my_queue()}.
take_first_alive_waiter(Queue) ->
    case queue:out(Queue) of
        {empty, _}              -> empty;
        {{value, From}, Queue2} ->
            {Pid, _} = From,
            case is_process_alive(Pid) of
                false -> take_first_alive_waiter(Queue2);
                true  -> {From, Queue2}
            end
    end.

-spec safe_gen_server_call(manager_ref(), term(), timeout()) -> term() | {error, Reason} when
      Reason :: {timeout, manager_ref()} | {noproc, manager_ref()} | term().
safe_gen_server_call(ManagerRef, Message, Timeout) ->
    try
        gen_server:call(ManagerRef, Message, Timeout)
    catch
        exit:{timeout, _} -> {error, {timeout, ManagerRef}};
        exit:{noproc, _}  -> {error, {noproc, ManagerRef}};
        Class:Reason      -> {error, {exception, Class, Reason, erlang:get_stacktrace()}}
    end.

-spec safe_gen_server_call(manager_ref(), term()) -> term() | {error, Reason} when
      Reason :: {timeout, manager_ref()} | {noproc, manager_ref()} | term().
safe_gen_server_call(ManagerRef, Message) ->
    safe_gen_server_call(ManagerRef, Message, 5000).

-spec do_find_entity(entity_id(), #?STATE{}) -> {ok, entity()} | {error, Reason} when
      Reason :: not_found.
do_find_entity(Id, State) ->
    case ets:lookup(State#?STATE.id_to_entity, Id) of
        []       -> {error, not_found};
        [Entity] -> {ok, Entity}
    end.

-spec do_find_entity_by_attributes([attribute()], #?STATE{}) -> {ok, [entity()]}.
do_find_entity_by_attributes(Attributes, State) ->
    #?STATE{id_to_entity = IdToEntity, attr_to_ids = AttrToIds} = State,
    {_, IdSet} =
        lists:foldl(
          fun (Attr, {IsFirst, AccSet}) ->
                  case dict:find(Attr, AttrToIds) of
                      error     -> {false, gb_sets:empty()};
                      {ok, Set} -> {false, case IsFirst of true -> Set; false -> gb_sets:intersection(Set, AccSet) end}
                  end
          end,
          {true, gb_sets:empty()},
          Attributes),
    Entities =
        gb_sets:fold(
          fun (Id, Acc) ->
                  [Entity] = ets:lookup(IdToEntity, Id),
                  [Entity | Acc]
          end,
          [],
          IdSet),
    {ok, Entities}.

-spec do_delete_entity({entity_id(),term()}, #?STATE{}) -> #?STATE{}.
do_delete_entity({Id, Reason}, State) ->
    _ = case ets:lookup(State#?STATE.id_to_entity, Id) of
            []            -> ok;
            [{_, Pid, _}] -> exit_entity(Pid, Reason, State)
        end,
    State.

-spec do_get_entities(#?STATE{}) -> {ok, [entity()]}.
do_get_entities(State) ->
    {ok, ets:tab2list(State#?STATE.id_to_entity)}.

-spec exit_entity(pid(), term(), #?STATE{}) -> ok.
exit_entity(Pid, Reason, State) ->
    _ = case State#?STATE.shutdown of
            brutal_kill -> exit(Pid, kill);
            infinity    -> exit(Pid, Reason);
            Timeout     ->
                true = exit(Pid, Reason),
                erlang:send_after(Timeout, self(), {exit_timeout, Pid})
        end,
    ok.

-spec exit_all_entity(term(), #?STATE{}) -> ok.
exit_all_entity(Reason, State) ->
    #?STATE{id_to_entity = IdToEntity} = State,
    _ = ets:foldl(fun ({_, Pid, _}, _) -> exit_entity(Pid, Reason, State) end, ok, IdToEntity),

    _ = ets:foldl(fun ({_, Pid, _}, _) ->
                          receive
                              {'EXIT', Pid, _}    -> ok;
                              {exit_timeout, Pid} -> exit(Pid, kill)
                          end
                  end,
                  ok,
                  IdToEntity),
    ok.

-spec safe_ets_lookup(atom(), term()) -> {ok, [term()]} | {error, Reason::term()}.
safe_ets_lookup(Table, Key) ->
    try
        {ok, ets:lookup(Table, Key)}
    catch
        error:badarg ->
            {error, {no_ets_table, Table}};
        Class:Reason ->
            {error, {exception, Class, Reason, erlang:get_stacktrace()}}
    end.

-spec safe_ets_tab2list(atom()) -> {ok, [term()]} | {error, Reason::term()}.
safe_ets_tab2list(Table) ->
    try
        {ok, ets:tab2list(Table)}
    catch
        error:badarg ->
            {error, {no_ets_table, Table}};
        Class:Reason ->
            {error, {exception, Class, Reason, erlang:get_stacktrace()}}
    end.

-spec insert_entity_entry(entity(), #?STATE{}) -> #?STATE{}.
insert_entity_entry(Entity, State) ->
    {Id, Pid, Attributes} = Entity,
    IdSingleton = gb_sets:singleton(Id),

    true = ets:insert(State#?STATE.id_to_entity, Entity),
    PidToId   = dict:store(Pid, Id, State#?STATE.pid_to_id),
    AttrToIds = lists:foldl(
                  fun (Attr, Acc) ->
                          dict:update(Attr, fun (Set) -> gb_sets:insert(Id, Set) end, IdSingleton, Acc)
                  end,
                  State#?STATE.attr_to_ids,
                  Attributes),
    State#?STATE{pid_to_id = PidToId, attr_to_ids = AttrToIds}.

-spec delete_entity_entry(entity(), #?STATE{}) -> #?STATE{}.
delete_entity_entry(Entity, State) ->
    {Id, Pid, Attributes} = Entity,
    true = ets:delete(State#?STATE.id_to_entity, Id),
    PidToId    = dict:erase(Pid, State#?STATE.pid_to_id),
    AttrToPids =
        lists:foldl(
          fun (Attr, AccAttrToPids) ->
                  IdSet0 = dict:fetch(Attr, AccAttrToPids),
                  IdSet1 = gb_sets:delete(Id, IdSet0),
                  case gb_sets:is_empty(IdSet1) of
                      true  -> dict:erase(Attr, AccAttrToPids);
                      false -> dict:store(Attr, IdSet1, AccAttrToPids)
                  end
          end,
          State#?STATE.attr_to_ids,
          Attributes),
    State#?STATE{pid_to_id = PidToId, attr_to_ids = AttrToPids}.

-spec handle_event_if_exported(module(), term()) -> ok.
handle_event_if_exported(Module, Event) ->
    _ = case erlang:function_exported(Module, handle_event, 1) of
            false -> ok;
            true  ->
                try Module:handle_event(Event) of
                    _ -> ok
                catch
                    Class:Reason ->
                        error_logger:warning_msg("~p:handle_event/1 error(~p): reason=~p, event=~p, trace=~p",
                                                 [Module, Class, Reason, Event, erlang:get_stacktrace()])
                end
        end,
    ok.
