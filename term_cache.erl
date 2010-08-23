% Copyright 2010,  Filipe David Manana  <fdmanana@apache.org>
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

-module(term_cache).
-behaviour(gen_server).

% public API
-export([start_link/1, stop/1]).
-export([get/2, put/3]).
-export([run_tests/0]).

% gen_server callbacks
-export([init/1, handle_call/3, handle_info/2, handle_cast/2]).
-export([code_change/3, terminate/2]).

-record(state, {
    max_cache_size = 100,
    cache_size = 0,
    policy = lru,
    timeout = 0,  % milliseconds
    items_ets,
    atimes_ets
}).

%% @type cache() = pid() | atom()
%% @type key() = term()
%% @type item() = term()


%% @spec get(cache(), key()) -> {ok, item()} | not_found
get(Cache, Key) ->
    gen_server:call(Cache, {get, Key}, infinity).


%% @spec put(cache(), key(), item()) -> ok
put(Cache, Key, Item) ->
    ok = gen_server:cast(Cache, {put, Key, Item}).


%% @spec start_link(options()) -> {ok, pid()}
%% @type options() = [ option() ]
%% @type option() = {name, atom()} | {policy, policy()} | {size, int()} |
%%                   {ttl, int()}
%% @type policy() = lru | mru
start_link(Options) ->
    Name = value(name, Options, ?MODULE),
    gen_server:start_link({local, Name}, ?MODULE, Options, []).


%% @spec stop(cache()) -> ok
stop(Cache) ->
    ok = gen_server:call(Cache, stop).


init(Options) ->
    State = #state{
        policy = value(policy, Options, lru),
        max_cache_size = value(size, Options, 100),
        timeout = value(ttl, Options, 0),  % 0 means no timeout
        items_ets = ets:new(cache_by_items_ets, [set, private]),
        atimes_ets = ets:new(cache_by_atimes_ets, [ordered_set, private])
    },
    {ok, State}.


handle_cast({put, Key, Item}, #state{timeout = Timeout} = State) ->
    #state{
        cache_size = CacheSize1,
        max_cache_size = MaxSize,
        items_ets = Items,
        atimes_ets = ATimes
    } = State,
    CacheSize = case ets:lookup(Items, Key) of
    [] ->
        CacheSize1;
    [{Key, {_OldItem, OldATime, _OldTimer}}] ->
        free_cache_entry(fun() -> OldATime end, State),
        CacheSize1 - 1
    end,
    case CacheSize >= MaxSize of
    true ->
        free_cache_entry(State);
    false ->
        ok
    end,
    ATime = erlang:now(),
    Timer = set_timer(Key, Timeout),
    true = ets:insert(ATimes, {ATime, Key}),
    true = ets:insert(Items, {Key, {Item, ATime, Timer}}),
    {noreply, State#state{cache_size = value(size, ets:info(Items))}}.


handle_call({get, Key}, _From, #state{timeout = Timeout} = State) ->
    #state{items_ets = Items, atimes_ets = ATimes} = State,
    case ets:lookup(Items, Key) of
    [{Key, {Item, ATime, Timer}}] ->
        cancel_timer(Key, Timer),
        NewATime = erlang:now(),
        true = ets:delete(ATimes, ATime),
        true = ets:insert(ATimes, {NewATime, Key}),
        NewTimer = set_timer(Key, Timeout),
        true = ets:insert(Items, {Key, {Item, NewATime, NewTimer}}),
        {reply, {ok, Item}, State};
    [] ->
        {reply, not_found, State}
    end;

handle_call(stop, _From, State) ->
    {stop, normal, ok, State}.


handle_info({expired, Key}, #state{cache_size = CacheSize} = State) ->
    #state{items_ets = Items, atimes_ets = ATimes} = State,
    [{Key, {_Item, ATime, _Timer}}] = ets:lookup(Items, Key),
    true = ets:delete(Items, Key),
    true = ets:delete(ATimes, ATime),
    {noreply, State#state{cache_size = CacheSize - 1}}.


terminate(_Reason, #state{items_ets = Items, atimes_ets = ATimes}) ->
    true = ets:delete(Items),
    true = ets:delete(ATimes).


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


free_cache_entry(#state{policy = lru, atimes_ets = ATimes} = State) ->
    free_cache_entry(fun() -> ets:first(ATimes) end, State);

free_cache_entry(#state{policy = mru, atimes_ets = ATimes} = State) ->
    free_cache_entry(fun() -> ets:last(ATimes) end, State).

free_cache_entry(ATimeFun, #state{items_ets = Items, atimes_ets = ATimes}) ->
    case ATimeFun() of
    '$end_of_table' ->
        ok;  % empty cache
    ATime ->
        [{ATime, Key}] = ets:lookup(ATimes, ATime),
        [{Key, {_Item, ATime, Timer}}] = ets:lookup(Items, Key),
        cancel_timer(Key, Timer),
        true = ets:delete(ATimes, ATime),
        true = ets:delete(Items, Key)
    end.


set_timer(_Key, 0) ->
    undefined;
set_timer(Key, Interval) when Interval > 0 ->
    erlang:send_after(Interval, self(), {expired, Key}).


cancel_timer(_Key, undefined) ->
    ok;
cancel_timer(Key, Timer) ->
    case erlang:cancel_timer(Timer) of
    false ->
        ok;
    _TimeLeft ->
        receive {expired, Key} -> ok after 0 -> ok end
    end.


% helper functions

value(Key, List) ->
    value(Key, List, undefined).

value(Key, List, Default) ->
    case lists:keysearch(Key, 1, List) of
    {value, {Key, Value}} ->
        Value;
    false ->
        Default
    end.


% TESTS

run_tests() ->
    ok = test_simple_lru(),
    ok = test_simple_mru(),
    ok = test_timed_lru(),
    ok = test_timed_mru().

test_simple_lru() ->
    {ok, Cache} = ?MODULE:start_link(
        [{name, foobar}, {size, 3}, {policy, lru}]
    ),
    Cache = whereis(foobar),
    not_found = ?MODULE:get(Cache, key1),
    ok = ?MODULE:put(Cache, key1, value1),
    {ok, value1} = ?MODULE:get(Cache, key1),
    ok = ?MODULE:put(Cache, <<"key_2">>, [1, 2, 3]),
    {ok, [1, 2, 3]} = ?MODULE:get(Cache, <<"key_2">>),
    ok = ?MODULE:put(Cache, {key, "3"}, {ok, 666}),
    {ok, {ok, 666}} = ?MODULE:get(Cache, {key, "3"}),
    ok = ?MODULE:put(Cache, "key4", "hello"),
    {ok, "hello"} = ?MODULE:get(Cache, "key4"),
    not_found = ?MODULE:get(Cache, key1),
    {ok, [1, 2, 3]} = ?MODULE:get(Cache, <<"key_2">>),
    {ok, {ok, 666}} = ?MODULE:get(Cache, {key, "3"}),
    ok = ?MODULE:put(Cache, 666, "the beast"),
    {ok, "the beast"} = ?MODULE:get(Cache, 666),
    not_found = ?MODULE:get(Cache, "key4"),
    ok = ?MODULE:stop(Cache).

test_simple_mru() ->
    {ok, Cache} = ?MODULE:start_link(
        [{name, foobar_mru}, {size, 3}, {policy, mru}]
    ),
    Cache = whereis(foobar_mru),
    not_found = ?MODULE:get(Cache, key1),
    ok = ?MODULE:put(Cache, key1, value1),
    {ok, value1} = ?MODULE:get(Cache, key1),
    ok = ?MODULE:put(Cache, <<"key_2">>, [1, 2, 3]),
    {ok, [1, 2, 3]} = ?MODULE:get(Cache, <<"key_2">>),
    ok = ?MODULE:put(Cache, {key, "3"}, {ok, 666}),
    {ok, {ok, 666}} = ?MODULE:get(Cache, {key, "3"}),
    ok = ?MODULE:put(Cache, "key4", "hello"),
    {ok, "hello"} = ?MODULE:get(Cache, "key4"),
    not_found = ?MODULE:get(Cache, {key, "3"}),
    {ok, value1} = ?MODULE:get(Cache, key1),
    ok = ?MODULE:put(Cache, keyboard, "qwerty"),
    {ok, "qwerty"} = ?MODULE:get(Cache, keyboard),
    not_found = ?MODULE:get(Cache, key1),
    ok = ?MODULE:stop(Cache).

test_timed_lru() ->
    {ok, Cache} = ?MODULE:start_link(
        [{name, timed_foobar}, {size, 3}, {policy, lru}, {ttl, 3000}]
    ),
    Cache = whereis(timed_foobar),
    ok = ?MODULE:put(Cache, key1, value1),
    timer:sleep(1000),
    ok = ?MODULE:put(Cache, key2, value2),
    ok = ?MODULE:put(Cache, key3, value3),
    timer:sleep(2100),
    not_found = ?MODULE:get(Cache, key1),
    {ok, value2} = ?MODULE:get(Cache, key2),
    {ok, value3} = ?MODULE:get(Cache, key3),
    ok = ?MODULE:put(Cache, key4, value4),
    ok = ?MODULE:put(Cache, key5, value5),
    timer:sleep(1000),
    not_found = ?MODULE:get(Cache, key2),
    {ok, value3} = ?MODULE:get(Cache, key3),
    timer:sleep(3100),
    not_found = ?MODULE:get(Cache, key3),
    ok = ?MODULE:stop(Cache).

test_timed_mru() ->
    {ok, Cache} = ?MODULE:start_link(
        [{name, timed_foobar}, {size, 3}, {policy, mru}, {ttl, 3000}]
    ),
    Cache = whereis(timed_foobar),
    ok = ?MODULE:put(Cache, key1, value1),
    timer:sleep(1000),
    ok = ?MODULE:put(Cache, key2, value2),
    ok = ?MODULE:put(Cache, key3, value3),
    timer:sleep(2100),
    not_found = ?MODULE:get(Cache, key1),
    {ok, value2} = ?MODULE:get(Cache, key2),
    {ok, value3} = ?MODULE:get(Cache, key3),
    ok = ?MODULE:put(Cache, key4, value4),
    ok = ?MODULE:put(Cache, key5, value5),
    timer:sleep(1000),
    not_found = ?MODULE:get(Cache, key4),
    {ok, value3} = ?MODULE:get(Cache, key3),
    timer:sleep(3100),
    not_found = ?MODULE:get(Cache, key3),
    ok = ?MODULE:stop(Cache).
