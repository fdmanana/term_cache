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
% This implementation uses 2 ets tables per cache.
% NOTE: the maximum number of instantiated ets tables allowed by the Erlang VM
%       is limited.

-module(term_cache_ets).
-behaviour(gen_server).

% public API
-export([start_link/1, stop/1]).
-export([get/2, put/3]).
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


%% @spec get(cache(), key()) -> {ok, item()} | not_found
get(Cache, Key) ->
    gen_server:call(Cache, {get, Key}, infinity).


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
        cache_size = Size,
        free = Size,
        ttl = value(ttl, Options, ?DEFAULT_TTL),
        items = ets:new(cache_by_items, [set, private]),
        atimes = ets:new(cache_by_atimes, [ordered_set, private]),
        take_fun = case Policy of
            lru ->
                fun ets:first/1;
            mru ->
                fun ets:last/1
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
    true = ets:insert(ATimes, {Now, Key}),
    true = ets:insert(Items, {Key, {Item, ItemSize, Now, Timer}}),
    {noreply, State#state{free = Free - ItemSize}};

handle_cast(flush,
    #state{items = Items, atimes = ATimes, cache_size = Size} = State) ->
    ets:foldl(
        fun({Key, {_, _, _, Timer}}, _) -> cancel_timer(Key, Timer) end,
        ok,
        Items
    ),
    true = ets:delete_all_objects(Items),
    true = ets:delete_all_objects(ATimes),
    {noreply, State#state{free = Size}}.


handle_call({get, Key}, _From, State) ->
    #state{items = Items, atimes = ATimes, ttl = Ttl} = State,
    case ets:lookup(Items, Key) of
    [{Key, {Item, ItemSize, ATime, Timer}}] ->
        cancel_timer(Key, Timer),
        NewATime = erlang:now(),
        true = ets:delete(ATimes, ATime),
        true = ets:insert(ATimes, {NewATime, Key}),
        NewTimer = set_timer(Key, Ttl),
        true = ets:insert(Items, {Key, {Item, ItemSize, NewATime, NewTimer}}),
        {reply, {ok, Item}, State};
    [] ->
        {reply, not_found, State}
    end;

handle_call(stop, _From, State) ->
    {stop, normal, ok, State}.


handle_info({expired, Key}, State) ->
    #state{items = Items, atimes = ATimes, free = Free} = State,
    [{Key, {_Item, ItemSize, ATime, _Timer}}] = ets:lookup(Items, Key),
    true = ets:delete(Items, Key),
    true = ets:delete(ATimes, ATime),
    {noreply, State#state{free = Free + ItemSize}}.


terminate(_Reason, #state{items = Items, atimes = ATimes}) ->
    true = ets:delete(Items),
    true = ets:delete(ATimes).


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


purge_item(Key, #state{atimes = ATimes, items = Items, free = Free} = State) ->
    case ets:lookup(Items, Key) of
    [{Key, {_Item, ItemSize, ATime, Timer}}] ->
        cancel_timer(Key, Timer),
        true = ets:delete(ATimes, ATime),
        true = ets:delete(Items, Key),
        State#state{free = Free + ItemSize};
    [] ->
        State
    end.


free_until(#state{free = Free} = State, MinFreeSize) when Free >= MinFreeSize ->
    State;
free_until(State, MinFreeSize) ->
    State2 = free_cache_entry(State),
    free_until(State2, MinFreeSize).


free_cache_entry(#state{take_fun = TakeFun} = State) ->
    #state{atimes = ATimes, items = Items, free = Free} = State,
    ATime = TakeFun(ATimes),
    [{ATime, Key}] = ets:lookup(ATimes, ATime),
    [{Key, {_Item, ItemSize, ATime, Timer}}] = ets:lookup(Items, Key),
    cancel_timer(Key, Timer),
    true = ets:delete(ATimes, ATime),
    true = ets:delete(Items, Key),
    State#state{free = Free + ItemSize}.


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


% TESTS

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

parse_size_test() ->
    ?assertEqual(512, parse_size(512)),
    ?assertEqual(512, parse_size('512')),
    ?assertEqual(512, parse_size("512")),
    ?assertEqual(512, parse_size(<<"512">>)),
    ?assertEqual(512, parse_size("512b")),
    ?assertEqual(512, parse_size('512b ')),
    ?assertEqual(1024, parse_size("1Kb")),
    ?assertEqual(1024, parse_size(" 1KB ")),
    ?assertEqual(1048576, parse_size("1024Kb")),
    ?assertEqual(1048576, parse_size(<<"1Mb">>)),
    ?assertEqual(1048576, parse_size("1024Kb")),
    ?assertEqual(3145728, parse_size('3Mb')),
    ?assertEqual(4294967296, parse_size('4Gb')),
    ?assertEqual(4294967296, parse_size("4 GB")).


simple_lru_test() ->
    {ok, Cache} = ?MODULE:start_link(
        [{name, foobar}, {size, 9}, {policy, lru}]
    ),
    ?assertEqual(Cache, whereis(foobar)),

    ?assertEqual(not_found, ?MODULE:get(Cache, key1)),
    ?assertEqual(ok, ?MODULE:put(Cache, key1, <<"abc">>)),
    ?assertEqual({ok, <<"abc">>}, ?MODULE:get(Cache, key1)),
    ?assertEqual(ok, ?MODULE:put(Cache, key2, <<"foo">>)),
    ?assertEqual({ok, <<"foo">>}, ?MODULE:get(Cache, key2)),
    ?assertEqual(ok, ?MODULE:put(Cache, key3, <<"bar">>)),
    ?assertEqual({ok, <<"bar">>}, ?MODULE:get(Cache, key3)),

    ?assertEqual(ok, ?MODULE:put(Cache, keyfoo, <<"a_too_large_binary">>)),
    ?assertEqual(not_found, ?MODULE:get(Cache, keyfoo)),

    ?assertEqual(ok, ?MODULE:put(Cache, "key4", <<"qwe">>)),
    ?assertEqual({ok, <<"qwe">>}, ?MODULE:get(Cache, "key4")),
    ?assertEqual(not_found, ?MODULE:get(Cache, key1)),
    ?assertEqual({ok, <<"foo">>}, ?MODULE:get(Cache, key2)),
    ?assertEqual({ok, <<"bar">>}, ?MODULE:get(Cache, key3)),

    ?assertEqual(ok, ?MODULE:put(Cache, key5, <<"123">>)),
    ?assertEqual({ok, <<"123">>}, ?MODULE:get(Cache, key5)),
    ?assertEqual(ok, ?MODULE:put(Cache, key5, <<"321">>)),
    ?assertEqual({ok, <<"321">>}, ?MODULE:get(Cache, key5)),

    ?assertEqual(not_found, ?MODULE:get(Cache, "key4")),
    ?assertEqual(ok, ?MODULE:put(Cache, <<"key6">>, <<"666">>)),
    ?assertEqual({ok, <<"666">>}, ?MODULE:get(Cache, <<"key6">>)),

    ?assertEqual(ok, ?MODULE:put(Cache, key5, <<"777">>)),
    ?assertEqual({ok, <<"777">>}, ?MODULE:get(Cache, key5)),

    ?assertEqual(ok, ?MODULE:put(Cache, key7, <<"12345">>)),
    ?assertEqual({ok, <<"12345">>}, ?MODULE:get(Cache, key7)),
    ?assertEqual({ok, <<"777">>}, ?MODULE:get(Cache, key5)),
    ?assertEqual(not_found, ?MODULE:get(Cache, <<"key6">>)),

    ?assertEqual(ok, ?MODULE:put(Cache, key8, <<"X">>)),
    ?assertEqual({ok, <<"X">>}, ?MODULE:get(Cache, key8)),
    ?assertEqual({ok, <<"12345">>}, ?MODULE:get(Cache, key7)),
    ?assertEqual({ok, <<"777">>}, ?MODULE:get(Cache, key5)),

    ?assertEqual(ok, ?MODULE:put(Cache, key9, <<"Yz">>)),
    ?assertEqual({ok, <<"Yz">>}, ?MODULE:get(Cache, key9)),
    ?assertEqual({ok, <<"777">>}, ?MODULE:get(Cache, key5)),
    ?assertEqual(not_found, ?MODULE:get(Cache, key8)),
    ?assertEqual(not_found, ?MODULE:get(Cache, key7)),

    ?assertEqual(ok, ?MODULE:flush(Cache)),
    ?assertEqual(not_found, ?MODULE:get(Cache, key9)),
    ?assertEqual(not_found, ?MODULE:get(Cache, key5)),

    ?assertEqual(ok, ?MODULE:stop(Cache)).


simple_mru_test() ->
    {ok, Cache} = ?MODULE:start_link(
        [{name, foobar_mru}, {size, 9}, {policy, mru}]
    ),
    ?assertEqual(Cache, whereis(foobar_mru)),

    ?assertEqual(not_found, ?MODULE:get(Cache, key1)),
    ?assertEqual(ok, ?MODULE:put(Cache, key1, <<"abc">>)),
    ?assertEqual({ok, <<"abc">>}, ?MODULE:get(Cache, key1)),
    ?assertEqual(ok, ?MODULE:put(Cache, key2, <<"foo">>)),
    ?assertEqual({ok, <<"foo">>}, ?MODULE:get(Cache, key2)),
    ?assertEqual(ok, ?MODULE:put(Cache, key3, <<"bar">>)),
    ?assertEqual({ok, <<"bar">>}, ?MODULE:get(Cache, key3)),

    ?assertEqual(ok, ?MODULE:put(Cache, key4, <<"qwe">>)),
    ?assertEqual({ok, <<"qwe">>}, ?MODULE:get(Cache, key4)),
    ?assertEqual(not_found, ?MODULE:get(Cache, key3)),

    ?assertEqual(ok, ?MODULE:put(Cache, key1, <<"999">>)),
    ?assertEqual({ok, <<"999">>}, ?MODULE:get(Cache, key1)),
    ?assertEqual({ok, <<"foo">>}, ?MODULE:get(Cache, key2)),
    ?assertEqual({ok, <<"qwe">>}, ?MODULE:get(Cache, key4)),

    ?assertEqual(ok, ?MODULE:put(Cache, keyfoo, <<"a_too_large_binary">>)),
    ?assertEqual(not_found, ?MODULE:get(Cache, keyfoo)),

    ?assertEqual({ok, <<"999">>}, ?MODULE:get(Cache, key1)),
    ?assertEqual({ok, <<"foo">>}, ?MODULE:get(Cache, key2)),
    ?assertEqual({ok, <<"qwe">>}, ?MODULE:get(Cache, key4)),

    ?assertEqual(ok, ?MODULE:put(Cache, key5, <<"---">>)),
    ?assertEqual(not_found, ?MODULE:get(Cache, key4)),
    ?assertEqual(ok, ?MODULE:put(Cache, key6, <<"666">>)),
    ?assertEqual(not_found, ?MODULE:get(Cache, key5)),
    ?assertEqual({ok, <<"666">>}, ?MODULE:get(Cache, key6)),
    ?assertEqual({ok, <<"999">>}, ?MODULE:get(Cache, key1)),
    ?assertEqual({ok, <<"foo">>}, ?MODULE:get(Cache, key2)),

    ?assertEqual(ok, ?MODULE:put(Cache, key7, <<"x">>)),
    ?assertEqual(ok, ?MODULE:put(Cache, key8, <<"y">>)),
    ?assertEqual(ok, ?MODULE:put(Cache, key9, <<"z">>)),

    ?assertEqual({ok, <<"z">>}, ?MODULE:get(Cache, key9)),
    ?assertEqual({ok, <<"y">>}, ?MODULE:get(Cache, key8)),
    ?assertEqual({ok, <<"x">>}, ?MODULE:get(Cache, key7)),
    ?assertEqual(not_found, ?MODULE:get(Cache, key2)),
    ?assertEqual({ok, <<"666">>}, ?MODULE:get(Cache, key6)),
    ?assertEqual({ok, <<"999">>}, ?MODULE:get(Cache, key1)),

    ?assertEqual(ok, ?MODULE:put(Cache, key10, <<"--">>)),
    ?assertEqual({ok, <<"--">>}, ?MODULE:get(Cache, key10)),
    ?assertEqual({ok, <<"z">>}, ?MODULE:get(Cache, key9)),
    ?assertEqual({ok, <<"y">>}, ?MODULE:get(Cache, key8)),
    ?assertEqual({ok, <<"x">>}, ?MODULE:get(Cache, key7)),
    ?assertEqual({ok, <<"666">>}, ?MODULE:get(Cache, key6)),
    ?assertEqual(not_found, ?MODULE:get(Cache, key1)),

    ?assertEqual(ok, ?MODULE:flush(Cache)),
    ?assertEqual(not_found, ?MODULE:get(Cache, key10)),
    ?assertEqual(not_found, ?MODULE:get(Cache, key9)),
    ?assertEqual(not_found, ?MODULE:get(Cache, key8)),
    ?assertEqual(not_found, ?MODULE:get(Cache, key7)),
    ?assertEqual(not_found, ?MODULE:get(Cache, key6)),

    ?assertEqual(ok, ?MODULE:stop(Cache)).


timed_lru_test_() ->
    {timeout, 60, [fun do_test_timed_lru/0]}.

do_test_timed_lru() ->
    {ok, Cache} = ?MODULE:start_link(
        [{name, timed_foobar}, {size, 9}, {policy, lru}, {ttl, 3000}]
    ),
    ?assertEqual(Cache, whereis(timed_foobar)),

    ?assertEqual(ok, ?MODULE:put(Cache, key1, <<"_1_">>)),
    timer:sleep(1000),

    ?assertEqual(ok, ?MODULE:put(Cache, key2, <<"-2-">>)),
    ?assertEqual(ok, ?MODULE:put(Cache, key3, <<"_3_">>)),
    timer:sleep(2100),

    ?assertEqual(not_found, ?MODULE:get(Cache, key1)),
    ?assertEqual({ok, <<"-2-">>}, ?MODULE:get(Cache, key2)),
    ?assertEqual({ok, <<"_3_">>}, ?MODULE:get(Cache, key3)),

    ?assertEqual(ok, ?MODULE:put(Cache, key4, <<"444">>)),
    ?assertEqual(ok, ?MODULE:put(Cache, key5, <<"555">>)),
    timer:sleep(1000),

    ?assertEqual(not_found, ?MODULE:get(Cache, key2)),
    ?assertEqual({ok, <<"_3_">>}, ?MODULE:get(Cache, key3)),
    timer:sleep(3100),

    ?assertEqual(not_found, ?MODULE:get(Cache, key3)),
    ?assertEqual(ok, ?MODULE:stop(Cache)).


timed_mru_test_() ->
    {timeout, 60, [fun do_test_timed_mru/0]}.

do_test_timed_mru() ->
    {ok, Cache} = ?MODULE:start_link(
        [{name, timed_foobar}, {size, 9}, {policy, mru}, {ttl, 3000}]
    ),
    ?assertEqual(Cache, whereis(timed_foobar)),

    ?assertEqual(ok, ?MODULE:put(Cache, key1, <<"111">>)),
    timer:sleep(1000),

    ?assertEqual(ok, ?MODULE:put(Cache, key2, <<"222">>)),
    ?assertEqual(ok, ?MODULE:put(Cache, key3, <<"333">>)),
    timer:sleep(2100),

    ?assertEqual(not_found, ?MODULE:get(Cache, key1)),
    ?assertEqual({ok, <<"222">>}, ?MODULE:get(Cache, key2)),
    ?assertEqual({ok, <<"333">>}, ?MODULE:get(Cache, key3)),

    ?assertEqual(ok, ?MODULE:put(Cache, key4, <<"444">>)),
    ?assertEqual(ok, ?MODULE:put(Cache, key5, <<"555">>)),
    timer:sleep(1000),

    ?assertEqual(not_found, ?MODULE:get(Cache, key4)),
    ?assertEqual({ok, <<"333">>}, ?MODULE:get(Cache, key3)),
    ?assertEqual({ok, <<"222">>}, ?MODULE:get(Cache, key2)),
    timer:sleep(3100),

    ?assertEqual(not_found, ?MODULE:get(Cache, key3)),
    ?assertEqual(not_found, ?MODULE:get(Cache, key2)),

    ?assertEqual(ok, ?MODULE:stop(Cache)).

-endif.
