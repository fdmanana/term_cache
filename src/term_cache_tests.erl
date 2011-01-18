-module(term_cache_tests).
-include_lib("eunit/include/eunit.hrl").


term_cache_dict_simple_lru_test_() ->
    {timeout, 60, [fun() -> test_simple_lru(term_cache_dict) end]}.

term_cache_ets_simple_lru_test_() ->
    {timeout, 60, [fun() -> test_simple_lru(term_cache_ets) end]}.

term_cache_pdict_simple_lru_test_() ->
    {timeout, 60, [fun() -> test_simple_lru(term_cache_pdict) end]}.

term_cache_trees_simple_lru_test_() ->
    {timeout, 60, [fun() -> test_simple_lru(term_cache_trees) end]}.

test_simple_lru(Module) ->
    {ok, Cache} = Module:start_link(
        [{name, foobar}, {size, 9}, {policy, lru}]
    ),
    ?assertEqual(Cache, whereis(foobar)),

    ?assertEqual(not_found, Module:get(Cache, key1)),
    ?assertEqual(ok, Module:put(Cache, key1, <<"abc">>)),
    ?assertEqual({ok, <<"abc">>}, Module:get(Cache, key1)),
    ?assertEqual(ok, Module:put(Cache, key2, <<"foo">>)),
    ?assertEqual({ok, <<"foo">>}, Module:get(Cache, key2)),
    ?assertEqual(ok, Module:put(Cache, key3, <<"bar">>)),
    ?assertEqual({ok, <<"bar">>}, Module:get(Cache, key3)),

    ?assertEqual(ok, Module:put(Cache, keyfoo, <<"a_too_large_binary">>)),
    ?assertEqual(not_found, Module:get(Cache, keyfoo)),

    ?assertEqual(ok, Module:put(Cache, "key4", <<"qwe">>)),
    ?assertEqual({ok, <<"qwe">>}, Module:get(Cache, "key4")),
    ?assertEqual(not_found, Module:get(Cache, key1)),
    ?assertEqual({ok, <<"foo">>}, Module:get(Cache, key2)),
    ?assertEqual({ok, <<"bar">>}, Module:get(Cache, key3)),

    ?assertEqual(ok, Module:put(Cache, key5, <<"123">>)),
    ?assertEqual({ok, <<"123">>}, Module:get(Cache, key5)),
    ?assertEqual(ok, Module:put(Cache, key5, <<"321">>)),
    ?assertEqual({ok, <<"321">>}, Module:get(Cache, key5)),

    ?assertEqual(not_found, Module:get(Cache, "key4")),
    ?assertEqual(ok, Module:put(Cache, <<"key6">>, <<"666">>)),
    ?assertEqual({ok, <<"666">>}, Module:get(Cache, <<"key6">>)),

    ?assertEqual(ok, Module:put(Cache, key5, <<"777">>)),
    ?assertEqual({ok, <<"777">>}, Module:get(Cache, key5)),

    ?assertEqual(ok, Module:put(Cache, key7, <<"12345">>)),
    ?assertEqual({ok, <<"12345">>}, Module:get(Cache, key7)),
    ?assertEqual({ok, <<"777">>}, Module:get(Cache, key5)),
    ?assertEqual(not_found, Module:get(Cache, <<"key6">>)),

    ?assertEqual(ok, Module:put(Cache, key8, <<"X">>)),
    ?assertEqual({ok, <<"X">>}, Module:get(Cache, key8)),
    ?assertEqual({ok, <<"12345">>}, Module:get(Cache, key7)),
    ?assertEqual({ok, <<"777">>}, Module:get(Cache, key5)),

    ?assertEqual(ok, Module:put(Cache, key9, <<"Yz">>)),
    ?assertEqual({ok, <<"Yz">>}, Module:get(Cache, key9)),
    ?assertEqual({ok, <<"777">>}, Module:get(Cache, key5)),
    ?assertEqual(not_found, Module:get(Cache, key8)),
    ?assertEqual(not_found, Module:get(Cache, key7)),

    ?assertEqual(ok, Module:update(Cache, key9, <<"Ya">>)),
    ?assertEqual({ok, <<"Ya">>}, Module:get(Cache, key9)),
    ?assertEqual({ok, <<"777">>}, Module:get(Cache, key5)),
    ?assertEqual(ok, Module:update(Cache, key999, <<"V">>)),
    ?assertEqual(not_found, Module:get(Cache, key999)),
    ?assertEqual({ok, <<"Ya">>}, Module:get(Cache, key9)),
    ?assertEqual({ok, <<"777">>}, Module:get(Cache, key5)),

    % updating a key's item doesn't update its timestamp
    ?assertEqual(ok, Module:update(Cache, key9, <<"YY">>)),
    ?assertEqual(ok, Module:put(Cache, key10, <<"54321">>)),
    ?assertEqual({ok, <<"54321">>}, Module:get(Cache, key10)),
    ?assertEqual({ok, <<"777">>}, Module:get(Cache, key5)),
    ?assertEqual(not_found, Module:get(Cache, key9)),

    ?assertEqual(ok, Module:flush(Cache)),
    ?assertEqual(not_found, Module:get(Cache, key9)),
    ?assertEqual(not_found, Module:get(Cache, key5)),
    ?assertEqual(not_found, Module:get(Cache, key10)),

    ?assertEqual(ok, Module:stop(Cache)).



term_cache_dict_simple_mru_test_() ->
    {timeout, 60, [fun() -> test_simple_mru(term_cache_dict) end]}.

term_cache_ets_simple_mru_test_() ->
    {timeout, 60, [fun() -> test_simple_mru(term_cache_ets) end]}.

term_cache_pdict_simple_mru_test_() ->
    {timeout, 60, [fun() -> test_simple_mru(term_cache_pdict) end]}.

term_cache_trees_simple_mru_test_() ->
    {timeout, 60, [fun() -> test_simple_mru(term_cache_trees) end]}.

test_simple_mru(Module) ->
    {ok, Cache} = Module:start_link(
        [{name, foobar_mru}, {size, 9}, {policy, mru}]
    ),
    ?assertEqual(Cache, whereis(foobar_mru)),

    ?assertEqual(not_found, Module:get(Cache, key1)),
    ?assertEqual(ok, Module:put(Cache, key1, <<"abc">>)),
    ?assertEqual({ok, <<"abc">>}, Module:get(Cache, key1)),
    ?assertEqual(ok, Module:put(Cache, key2, <<"foo">>)),
    ?assertEqual({ok, <<"foo">>}, Module:get(Cache, key2)),
    ?assertEqual(ok, Module:put(Cache, key3, <<"bar">>)),
    ?assertEqual({ok, <<"bar">>}, Module:get(Cache, key3)),

    ?assertEqual(ok, Module:put(Cache, key4, <<"qwe">>)),
    ?assertEqual({ok, <<"qwe">>}, Module:get(Cache, key4)),
    ?assertEqual(not_found, Module:get(Cache, key3)),

    ?assertEqual(ok, Module:put(Cache, key1, <<"999">>)),
    ?assertEqual({ok, <<"999">>}, Module:get(Cache, key1)),
    ?assertEqual({ok, <<"foo">>}, Module:get(Cache, key2)),
    ?assertEqual({ok, <<"qwe">>}, Module:get(Cache, key4)),

    ?assertEqual(ok, Module:put(Cache, keyfoo, <<"a_too_large_binary">>)),
    ?assertEqual(not_found, Module:get(Cache, keyfoo)),

    ?assertEqual({ok, <<"999">>}, Module:get(Cache, key1)),
    ?assertEqual({ok, <<"foo">>}, Module:get(Cache, key2)),
    ?assertEqual({ok, <<"qwe">>}, Module:get(Cache, key4)),

    ?assertEqual(ok, Module:put(Cache, key5, <<"---">>)),
    ?assertEqual(not_found, Module:get(Cache, key4)),
    ?assertEqual(ok, Module:put(Cache, key6, <<"666">>)),
    ?assertEqual(not_found, Module:get(Cache, key5)),
    ?assertEqual({ok, <<"666">>}, Module:get(Cache, key6)),
    ?assertEqual({ok, <<"999">>}, Module:get(Cache, key1)),
    ?assertEqual({ok, <<"foo">>}, Module:get(Cache, key2)),

    ?assertEqual(ok, Module:put(Cache, key7, <<"x">>)),
    ?assertEqual(ok, Module:put(Cache, key8, <<"y">>)),
    ?assertEqual(ok, Module:put(Cache, key9, <<"z">>)),

    ?assertEqual({ok, <<"z">>}, Module:get(Cache, key9)),
    ?assertEqual({ok, <<"y">>}, Module:get(Cache, key8)),
    ?assertEqual({ok, <<"x">>}, Module:get(Cache, key7)),
    ?assertEqual(not_found, Module:get(Cache, key2)),
    ?assertEqual({ok, <<"666">>}, Module:get(Cache, key6)),
    ?assertEqual({ok, <<"999">>}, Module:get(Cache, key1)),

    ?assertEqual(ok, Module:put(Cache, key10, <<"--">>)),
    ?assertEqual({ok, <<"--">>}, Module:get(Cache, key10)),
    ?assertEqual({ok, <<"z">>}, Module:get(Cache, key9)),
    ?assertEqual({ok, <<"y">>}, Module:get(Cache, key8)),
    ?assertEqual({ok, <<"x">>}, Module:get(Cache, key7)),
    ?assertEqual({ok, <<"666">>}, Module:get(Cache, key6)),
    ?assertEqual(not_found, Module:get(Cache, key1)),

    ?assertEqual(ok, Module:flush(Cache)),
    ?assertEqual(not_found, Module:get(Cache, key10)),
    ?assertEqual(not_found, Module:get(Cache, key9)),
    ?assertEqual(not_found, Module:get(Cache, key8)),
    ?assertEqual(not_found, Module:get(Cache, key7)),
    ?assertEqual(not_found, Module:get(Cache, key6)),

    ?assertEqual(ok, Module:put(Cache, key22, <<"abc">>)),
    ?assertEqual(ok, Module:put(Cache, key33, <<"abz">>)),
    ?assertEqual(ok, Module:put(Cache, key44, <<"abx">>)),

    ?assertEqual(ok, Module:update(Cache, key44, <<"ZZZ">>)),
    ?assertEqual({ok, <<"ZZZ">>}, Module:get(Cache, key44)),

    % updating a key's item doesn't update its timestamp
    ?assertEqual(ok, Module:update(Cache, key22, <<"AAA">>)),
    ?assertEqual(ok, Module:put(Cache, key55, <<":::">>)),
    ?assertEqual({ok, <<":::">>}, Module:get(Cache, key55)),
    ?assertEqual({ok, <<"AAA">>}, Module:get(Cache, key22)),
    ?assertEqual(not_found, Module:get(Cache, key44)),

    ?assertEqual(ok, Module:stop(Cache)).



term_cache_dict_timed_lru_test_() ->
    {timeout, 60, [fun() -> test_timed_lru(term_cache_dict) end]}.

term_cache_ets_timed_lru_test_() ->
    {timeout, 60, [fun() -> test_timed_lru(term_cache_ets) end]}.

term_cache_pdict_timed_lru_test_() ->
    {timeout, 60, [fun() -> test_timed_lru(term_cache_pdict) end]}.

term_cache_trees_timed_lru_test_() ->
    {timeout, 60, [fun() -> test_timed_lru(term_cache_trees) end]}.

test_timed_lru(Module) ->
    {ok, Cache} = Module:start_link(
        [{name, timed_foobar}, {size, 9}, {policy, lru}, {ttl, 3000}]
    ),
    ?assertEqual(Cache, whereis(timed_foobar)),

    ?assertEqual(ok, Module:put(Cache, key1, <<"_1_">>)),
    timer:sleep(1000),

    ?assertEqual(ok, Module:put(Cache, key2, <<"-2-">>)),
    ?assertEqual(ok, Module:put(Cache, key3, <<"_3_">>)),
    timer:sleep(2100),

    ?assertEqual(not_found, Module:get(Cache, key1)),
    ?assertEqual({ok, <<"-2-">>}, Module:get(Cache, key2)),
    ?assertEqual({ok, <<"_3_">>}, Module:get(Cache, key3)),

    ?assertEqual(ok, Module:put(Cache, key4, <<"444">>)),
    ?assertEqual(ok, Module:put(Cache, key5, <<"555">>)),
    timer:sleep(1000),

    ?assertEqual(not_found, Module:get(Cache, key2)),
    ?assertEqual({ok, <<"_3_">>}, Module:get(Cache, key3)),
    timer:sleep(3100),

    ?assertEqual(not_found, Module:get(Cache, key3)),
    ?assertEqual(ok, Module:stop(Cache)).



term_cache_dict_timed_mru_test_() ->
    {timeout, 60, [fun() -> test_timed_mru(term_cache_dict) end]}.

term_cache_ets_timed_mru_test_() ->
    {timeout, 60, [fun() -> test_timed_mru(term_cache_ets) end]}.

term_cache_pdict_timed_mru_test_() ->
    {timeout, 60, [fun() -> test_timed_mru(term_cache_pdict) end]}.

term_cache_trees_timed_mru_test_() ->
    {timeout, 60, [fun() -> test_timed_mru(term_cache_trees) end]}.

test_timed_mru(Module) ->
    {ok, Cache} = Module:start_link(
        [{name, timed_foobar}, {size, 9}, {policy, mru}, {ttl, 3000}]
    ),
    ?assertEqual(Cache, whereis(timed_foobar)),

    ?assertEqual(ok, Module:put(Cache, key1, <<"111">>)),
    timer:sleep(1000),

    ?assertEqual(ok, Module:put(Cache, key2, <<"222">>)),
    ?assertEqual(ok, Module:put(Cache, key3, <<"333">>)),
    timer:sleep(2100),

    ?assertEqual(not_found, Module:get(Cache, key1)),
    ?assertEqual({ok, <<"222">>}, Module:get(Cache, key2)),
    ?assertEqual({ok, <<"333">>}, Module:get(Cache, key3)),

    ?assertEqual(ok, Module:put(Cache, key4, <<"444">>)),
    ?assertEqual(ok, Module:put(Cache, key5, <<"555">>)),
    timer:sleep(1000),

    ?assertEqual(not_found, Module:get(Cache, key4)),
    ?assertEqual({ok, <<"333">>}, Module:get(Cache, key3)),
    ?assertEqual({ok, <<"222">>}, Module:get(Cache, key2)),
    timer:sleep(3100),

    ?assertEqual(not_found, Module:get(Cache, key3)),
    ?assertEqual(not_found, Module:get(Cache, key2)),

    ?assertEqual(ok, Module:stop(Cache)).
