% Copyright 2010,  Filipe David Manana  <fdmanana@apache.org>
% Web site:  http://github.com/fdmanana/term_cache
%
% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

% A simple, configurable and generic Erlang term cache.
% Keys and values can be any Erlang term.
%
% This implementation uses a tree (gb_trees module) to store the access times
% and a dictionary (dict module) to store the values.


-module(term_cache_dict).
-behaviour(gen_server).

% public API
-export([start_link/1, stop/1]).
-export([get/2, get/3, put/3]).
-export([flush/1]).

% gen_server callbacks
-export([init/1, handle_call/3, handle_info/2, handle_cast/2]).
-export([code_change/3, terminate/2]).

-define(DEFAULT_POLICY, lru).
-define(DEFAULT_SIZE, "128Kb").    % bytes
-define(DEFAULT_TTL, 0).           % 0 means no TTL

-record(state, {
    cache_size,
    free,       % free space
    policy,
    ttl,        % milliseconds
    items,
    atimes,
    take_fun
}).

%% @type cache() = pid() | atom()
%% @type key() = term()
%% @type item() = term()
%% @type timeout() = int()


%% @spec get(cache(), key()) -> {ok, item()} | not_found
get(Cache, Key) ->
    gen_server:call(Cache, {get, Key}, infinity).


%% @spec get(cache(), key(), timeout()) -> {ok, item()} | not_found | timeout
get(Cache, Key, Timeout) ->
    try
        gen_server:call(Cache, {get, Key}, Timeout)
    catch
    exit:{timeout, {gen_server, call, [Cache, {get, Key}, Timeout]}} ->
        timeout
    end.


%% @spec put(cache(), key(), item()) -> ok
put(Cache, Key, Item) ->
    ok = gen_server:cast(Cache, {put, Key, Item, term_size(Item)}).


%% @spec flush(cache()) -> ok
flush(Cache) ->
    ok = gen_server:cast(Cache, flush).


%% @spec start_link(options()) -> {ok, pid()}
%% @type options() = [ option() ]
%% @type option() = {name, atom()} | {policy, policy()} | {size, size()} |
%%                   {ttl, int()}
%% @type size() = int() | string() | binary() | atom()
%% @type policy() = lru | mru
start_link(Options) ->
    case value(name, Options, undefined) of
    undefined ->
        gen_server:start_link(?MODULE, Options, []);
    Name ->
        gen_server:start_link({local, Name}, ?MODULE, Options, [])
    end.


%% @spec stop(cache()) -> ok
stop(Cache) ->
    catch gen_server:call(Cache, stop),
    ok.


init(Options) ->
    Size = parse_size(value(size, Options, ?DEFAULT_SIZE)),
    Policy= value(policy, Options, ?DEFAULT_POLICY),
    State = #state{
        policy = Policy,
        cache_size = Size, % byte size
        free = Size,
        ttl = value(ttl, Options, ?DEFAULT_TTL),
        items = dict:new(),
        atimes = gb_trees:empty(),
        take_fun = case Policy of
            lru ->
                fun gb_trees:take_smallest/1;
            mru ->
                fun gb_trees:take_largest/1
            end
    },
    {ok, State}.


handle_cast({put, _Key, _Item, ItemSize},
    #state{cache_size = CacheSize} = State) when ItemSize > CacheSize ->
    {noreply, State};

handle_cast({put, Key, Item, ItemSize}, State) ->
    #state{
        items = Items,
        atimes = ATimes,
        ttl = Ttl,
        free = Free
    } = free_until(purge_item(Key, State), ItemSize),
    Now = erlang:now(),
    Timer = set_timer(Key, Ttl),
    ATimes2 = gb_trees:insert(Now, Key, ATimes),
    Items2 = dict:store(Key, {Item, ItemSize, Now, Timer}, Items),
    NewState = State#state{
        items = Items2,
        atimes = ATimes2,
        free = Free - ItemSize
    },
    {noreply, NewState};


handle_cast(flush, #state{items = Items, cache_size = Size} = State) ->
    dict:fold(
        fun(Key, {_, _, _, Timer}, _) -> cancel_timer(Key, Timer) end,
        ok,
        Items
    ),
    NewState = State#state{
        items = dict:new(),
        atimes = gb_trees:empty(),
        free = Size
    },
    {noreply, NewState}.


handle_call({get, Key}, _From, State) ->
    #state{items = Items, atimes = ATimes, ttl = T} = State,
    case dict:find(Key, Items) of
    {ok, {Item, ItemSize, ATime, Timer}} ->
        cancel_timer(Key, Timer),
        NewATime = erlang:now(),
        ATimes2 = gb_trees:insert(
            NewATime, Key, gb_trees:delete(ATime, ATimes)),
        Items2 = dict:store(
            Key, {Item, ItemSize, NewATime, set_timer(Key, T)}, Items),
        NewState = State#state{
            items = Items2,
            atimes = ATimes2
        },
        {reply, {ok, Item}, NewState};
    error ->
        {reply, not_found, State}
    end;

handle_call(stop, _From, State) ->
    {stop, normal, ok, State}.


handle_info({expired, Key}, State) ->
    #state{items = Items, atimes = ATimes, free = Free} = State,
    {_Item, ItemSize, ATime, _Timer} = dict:fetch(Key, Items),
    NewState = State#state{
        items = dict:erase(Key, Items),
        atimes = gb_trees:delete(ATime, ATimes),
        free = Free + ItemSize
    },
    {noreply, NewState}.


terminate(_Reason, _State) ->
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


purge_item(Key, #state{atimes = ATimes, items = Items, free = Free} = State) ->
    case dict:find(Key, Items) of
    {ok, {_Item, ItemSize, ATime, Timer}} ->
        cancel_timer(Key, Timer),
        State#state{
            atimes = gb_trees:delete(ATime, ATimes),
            items = dict:erase(Key, Items),
            free = Free + ItemSize
        };
    error ->
        State
    end.


free_until(#state{free = Free} = State, MinFreeSize) when Free >= MinFreeSize ->
    State;
free_until(State, MinFreeSize) ->
    State2 = free_cache_entry(State),
    free_until(State2, MinFreeSize).


free_cache_entry(#state{take_fun = TakeFun} = State) ->
    #state{atimes = ATimes, items = Items, free = Free} = State,
    {ATime, Key, ATimes2} = TakeFun(ATimes),
    {_Item, ItemSize, ATime, Timer} = dict:fetch(Key, Items),
    cancel_timer(Key, Timer),
    State#state{
        items = dict:erase(Key, Items),
        atimes = ATimes2,
        free = Free + ItemSize
    }.


set_timer(_Key, 0) ->
    undefined;
set_timer(Key, Interval) when Interval > 0 ->
    erlang:send_after(Interval, self(), {expired, Key}).


cancel_timer(_Key, undefined) ->
    ok;
cancel_timer(Key, Timer) ->
    case erlang:cancel_timer(Timer) of
    false ->
        receive {expired, Key} -> ok after 0 -> ok end;
    _TimeLeft ->
        ok
    end.


% helper functions

value(Key, List, Default) ->
    case lists:keysearch(Key, 1, List) of
    {value, {Key, Value}} ->
        Value;
    false ->
        Default
    end.


term_size(Term) when is_binary(Term) ->
    byte_size(Term);
term_size(Term) ->
    byte_size(term_to_binary(Term)).


parse_size(Size) when is_integer(Size) ->
    Size;
parse_size(Size) when is_atom(Size) ->
    parse_size(atom_to_list(Size));
parse_size(Size) ->
    {match, [Value1, Suffix]} = re:run(
        Size,
        [$^, "\\s*", "(\\d+)", "\\s*", "(\\w*)", "\\s*", $$],
        [{capture, [1, 2], list}]),
    Value = list_to_integer(Value1),
    case string:to_lower(Suffix) of
    [] ->
        Value;
    "b" ->
        Value;
    "kb" ->
        Value * 1024;
    "mb" ->
        Value * 1024 * 1024;
    "gb" ->
        Value * 1024 * 1024 * 1024
    end.
