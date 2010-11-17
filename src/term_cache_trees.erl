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
% This implementation uses trees (from gb_trees module) instead of ets tables.
% The reason for trees is that the maximum number of ets tables allowed by the
% Erlang VM is limited.

-module(term_cache_trees).
-behaviour(gen_server).

% public API
-export([start_link/1, stop/1]).
-export([get/2, put/3]).
-export([flush/1]).

% gen_server callbacks
-export([init/1, handle_call/3, handle_info/2, handle_cast/2]).
-export([code_change/3, terminate/2]).

-record(state, {
    max_cache_size = 100,
    policy = lru,
    timeout = 0,  % milliseconds
    items_tree,
    atimes_tree
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


%% @spec flush(cache()) -> ok
flush(Cache) ->
    ok = gen_server:cast(Cache, flush).


%% @spec start_link(options()) -> {ok, pid()}
%% @type options() = [ option() ]
%% @type option() = {name, atom()} | {policy, policy()} | {size, int()} |
%%                   {ttl, int()}
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
    State = #state{
        policy = value(policy, Options, lru),
        max_cache_size = value(size, Options, 100),
        timeout = value(ttl, Options, 0),  % 0 means no timeout
        items_tree = gb_trees:empty(),
        atimes_tree = gb_trees:empty()
    },
    {ok, State}.


handle_cast({put, _Key, _Item}, #state{max_cache_size = 0} = State) ->
    {noreply, State};
handle_cast({put, Key, Item}, #state{timeout = Timeout} = State) ->
    #state{
        max_cache_size = MaxSize,
        items_tree = Items,
        atimes_tree = ATimes
    } = State,
    {NewItems, NewATimes} = case gb_trees:lookup(Key, Items) of
    {value, {_OldItem, OldATime, OldTimer}} ->
        cancel_timer(Key, OldTimer),
        NewATime = erlang:now(),
        NewTimer = set_timer(Key, Timeout),
        Items2 = gb_trees:enter(Key, {Item, NewATime, NewTimer}, Items),
        ATimes2 = gb_trees:delete(OldATime, ATimes),
        {Items2, gb_trees:insert(NewATime, Key, ATimes2)};
    none ->
        {Items2, ATimes2} = case gb_trees:size(Items) >= MaxSize of
        true ->
            free_cache_entry(State);
        false ->
            {Items, ATimes}
        end,
        NewATime = erlang:now(),
        NewTimer = set_timer(Key, Timeout),
        ATimes3 = gb_trees:insert(NewATime, Key, ATimes2),
        Items3 = gb_trees:insert(Key, {Item, NewATime, NewTimer}, Items2),
        {Items3, ATimes3}
    end,
    {noreply, State#state{items_tree = NewItems, atimes_tree = NewATimes}};

handle_cast(flush, #state{items_tree = Items} = State) ->
    lists:foldl(
        fun({Key, {_Item, _ATime, Timer}}, _) -> cancel_timer(Key, Timer) end,
        ok,
        gb_trees:to_list(Items)
    ),
    NewState = State#state{
        items_tree = gb_trees:empty(),
        atimes_tree = gb_trees:empty()
    },
    {noreply, NewState}.


handle_call({get, Key}, _From, #state{timeout = Timeout} = State) ->
    #state{items_tree = Items, atimes_tree = ATimes} = State,
    case gb_trees:lookup(Key, Items) of
    {value, {Item, ATime, Timer}} ->
        cancel_timer(Key, Timer),
        NewATime = erlang:now(),
        ATimes2 = gb_trees:delete(ATime, ATimes),
        ATimes3 = gb_trees:insert(NewATime, Key, ATimes2),
        NewTimer = set_timer(Key, Timeout),
        Items2 = gb_trees:update(Key, {Item, NewATime, NewTimer}, Items),
        NewState = State#state{
            items_tree = Items2,
            atimes_tree = ATimes3
        },
        {reply, {ok, Item}, NewState};
    none ->
        {reply, not_found, State}
    end;

handle_call(stop, _From, State) ->
    {stop, normal, ok, State}.


handle_info({expired, Key}, State) ->
    #state{items_tree = Items, atimes_tree = ATimes} = State,
    {_Item, ATime, _Timer} = gb_trees:get(Key, Items),
    Items2 = gb_trees:delete(Key, Items),
    ATimes2 = gb_trees:delete(ATime, ATimes),
    {noreply, State#state{items_tree = Items2, atimes_tree = ATimes2}}.


terminate(_Reason, _State) ->
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


free_cache_entry(#state{policy = lru} = State) ->
    #state{atimes_tree = ATimes, items_tree = Items} = State,
    {ATime, Key, ATimes2} = gb_trees:take_smallest(ATimes),
    {_Item, ATime, Timer} = gb_trees:get(Key, Items),
    cancel_timer(Key, Timer),
    {gb_trees:delete(Key, Items), ATimes2};

free_cache_entry(#state{policy = mru} = State) ->
    #state{atimes_tree = ATimes, items_tree = Items} = State,
    {ATime, Key, ATimes2} = gb_trees:take_largest(ATimes),
    {_Item, ATime, Timer} = gb_trees:get(Key, Items),
    cancel_timer(Key, Timer),
    {gb_trees:delete(Key, Items), ATimes2}.


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

value(Key, List, Default) ->
    case lists:keysearch(Key, 1, List) of
    {value, {Key, Value}} ->
        Value;
    false ->
        Default
    end.


% TESTS

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

simple_lru_test() ->
    {ok, Cache} = ?MODULE:start_link(
        [{name, foobar}, {size, 3}, {policy, lru}]
    ),
    ?assertEqual(Cache, whereis(foobar)),
    ?assertEqual(not_found, ?MODULE:get(Cache, key1)),
    ?assertEqual(ok, ?MODULE:put(Cache, key1, value1)),
    ?assertEqual({ok, value1}, ?MODULE:get(Cache, key1)),
    ?assertEqual(ok, ?MODULE:put(Cache, <<"key_2">>, [1, 2, 3])),
    ?assertEqual({ok, [1, 2, 3]}, ?MODULE:get(Cache, <<"key_2">>)),
    ?assertEqual(ok, ?MODULE:put(Cache, {key, "3"}, {ok, 666})),
    ?assertEqual({ok, {ok, 666}}, ?MODULE:get(Cache, {key, "3"})),

    ?assertEqual(ok, ?MODULE:put(Cache, "key4", "hello")),
    ?assertEqual({ok, "hello"}, ?MODULE:get(Cache, "key4")),
    ?assertEqual(not_found, ?MODULE:get(Cache, key1)),
    ?assertEqual({ok, [1, 2, 3]}, ?MODULE:get(Cache, <<"key_2">>)),
    ?assertEqual({ok, {ok, 666}}, ?MODULE:get(Cache, {key, "3"})),
    ?assertEqual(ok, ?MODULE:put(Cache, 666, "the beast")),
    ?assertEqual({ok, "the beast"}, ?MODULE:get(Cache, 666)),
    ?assertEqual(ok, ?MODULE:put(Cache, 666, <<"maiden">>)),
    ?assertEqual({ok, <<"maiden">>}, ?MODULE:get(Cache, 666)),
    ?assertEqual(not_found, ?MODULE:get(Cache, "key4")),
    ?assertEqual(ok, ?MODULE:put(Cache, 999, <<"the saint">>)),
    ?assertEqual({ok, <<"the saint">>}, ?MODULE:get(Cache, 999)),
    ?assertEqual(ok, ?MODULE:put(Cache, 666, "the beast")),
    ?assertEqual({ok, "the beast"}, ?MODULE:get(Cache, 666)),
    ?assertEqual(ok, ?MODULE:flush(Cache)),
    ?assertEqual(not_found, ?MODULE:get(Cache, 666)),
    ?assertEqual(not_found, ?MODULE:get(Cache, <<"key_2">>)),
    ?assertEqual(not_found, ?MODULE:get(Cache, {key, "3"})),
    ?assertEqual(ok, ?MODULE:stop(Cache)).

simple_mru_test() ->
    {ok, Cache} = ?MODULE:start_link(
        [{name, foobar_mru}, {size, 3}, {policy, mru}]
    ),
    ?assertEqual(Cache, whereis(foobar_mru)),
    ?assertEqual(not_found, ?MODULE:get(Cache, key1)),
    ?assertEqual(ok, ?MODULE:put(Cache, key1, value1)),
    ?assertEqual({ok, value1}, ?MODULE:get(Cache, key1)),
    ?assertEqual(ok, ?MODULE:put(Cache, <<"key_2">>, [1, 2, 3])),
    ?assertEqual({ok, [1, 2, 3]}, ?MODULE:get(Cache, <<"key_2">>)),
    ?assertEqual(ok, ?MODULE:put(Cache, {key, "3"}, {ok, 666})),
    ?assertEqual({ok, {ok, 666}}, ?MODULE:get(Cache, {key, "3"})),
    ?assertEqual(ok, ?MODULE:put(Cache, "key4", "hello")),
    ?assertEqual({ok, "hello"}, ?MODULE:get(Cache, "key4")),
    ?assertEqual(not_found, ?MODULE:get(Cache, {key, "3"})),
    ?assertEqual({ok, value1}, ?MODULE:get(Cache, key1)),
    ?assertEqual(ok, ?MODULE:put(Cache, keyboard, "qwerty")),
    ?assertEqual({ok, "qwerty"}, ?MODULE:get(Cache, keyboard)),
    ?assertEqual(ok, ?MODULE:put(Cache, keyboard, "azwerty")),
    ?assertEqual({ok, "azwerty"}, ?MODULE:get(Cache, keyboard)),
    ?assertEqual(not_found, ?MODULE:get(Cache, key1)),
    ?assertEqual(ok, ?MODULE:flush(Cache)),
    ?assertEqual(not_found, ?MODULE:get(Cache, keyboard)),
    ?assertEqual(not_found, ?MODULE:get(Cache, "key4")),
    ?assertEqual(not_found, ?MODULE:get(Cache, <<"key_2">>)),
    ?assertEqual(ok, ?MODULE:stop(Cache)).

timed_lru_test_() ->
    {timeout, 60, [fun do_test_timed_lru/0]}.

do_test_timed_lru() ->
    {ok, Cache} = ?MODULE:start_link(
        [{name, timed_foobar}, {size, 3}, {policy, lru}, {ttl, 3000}]
    ),
    ?assertEqual(Cache, whereis(timed_foobar)),
    ?assertEqual(ok, ?MODULE:put(Cache, key1, value1)),
    timer:sleep(1000),
    ?assertEqual(ok, ?MODULE:put(Cache, key2, value2)),
    ?assertEqual(ok, ?MODULE:put(Cache, key3, value3)),
    timer:sleep(2100),
    ?assertEqual(not_found, ?MODULE:get(Cache, key1)),
    ?assertEqual({ok, value2}, ?MODULE:get(Cache, key2)),
    ?assertEqual({ok, value3}, ?MODULE:get(Cache, key3)),
    ?assertEqual(ok, ?MODULE:put(Cache, key4, value4)),
    ?assertEqual(ok, ?MODULE:put(Cache, key5, value5)),
    timer:sleep(1000),
    ?assertEqual(not_found, ?MODULE:get(Cache, key2)),
    ?assertEqual({ok, value3}, ?MODULE:get(Cache, key3)),
    timer:sleep(3100),
    ?assertEqual(not_found, ?MODULE:get(Cache, key3)),
    ?assertEqual(ok, ?MODULE:stop(Cache)).

timed_mru_test_() ->
    {timeout, 60, [fun do_test_timed_mru/0]}.

do_test_timed_mru() ->
    {ok, Cache} = ?MODULE:start_link(
        [{name, timed_foobar}, {size, 3}, {policy, mru}, {ttl, 3000}]
    ),
    ?assertEqual(Cache, whereis(timed_foobar)),
    ?assertEqual(ok, ?MODULE:put(Cache, key1, value1)),
    timer:sleep(1000),
    ?assertEqual(ok, ?MODULE:put(Cache, key2, value2)),
    ?assertEqual(ok, ?MODULE:put(Cache, key3, value3)),
    timer:sleep(2100),
    ?assertEqual(not_found, ?MODULE:get(Cache, key1)),
    ?assertEqual({ok, value2}, ?MODULE:get(Cache, key2)),
    ?assertEqual({ok, value3}, ?MODULE:get(Cache, key3)),
    ?assertEqual(ok, ?MODULE:put(Cache, key4, value4)),
    ?assertEqual(ok, ?MODULE:put(Cache, key5, value5)),
    timer:sleep(1000),
    ?assertEqual(not_found, ?MODULE:get(Cache, key4)),
    ?assertEqual({ok, value3}, ?MODULE:get(Cache, key3)),
    timer:sleep(3100),
    ?assertEqual(not_found, ?MODULE:get(Cache, key3)),
    ?assertEqual(ok, ?MODULE:stop(Cache)).

-endif.
