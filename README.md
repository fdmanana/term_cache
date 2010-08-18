# term_cache

This is a simple cache for Erlang implemented as an OTP gen_server.
Keys and values can be any Erlang term.

Each cache instance can be configured with the following parameters:

* {name, atom()} - name of the cache process
* {size, int()} - maximum size (number of items)
* {policy, lru | mru} - cache entry replacement policy
* {timeout, int()} - the Time To Live (TTL) for cache entries. If an entry is not accessed within this time period, it will be purged from the cache.


# usage example

    {ok, Cache} = term_cache:start_link([{name, foobar}, {size, 3}, {policy, lru}]),
    ok = term_cache:put(Cache, key1, value1),
    {ok, value1} = term_cache:get(Cache, key1),
    ok = term_cache:put(Cache, <<"key_2">>, [1, 2, 3]),
    {ok, [1, 2, 3]} = term_cache:get(Cache, <<"key_2">>),
    ok = term_cache:put(Cache, {key, "3"}, {ok, 666}),
    {ok, {ok, 666}} = term_cache:get(Cache, {key, "3"}),
    ok = term_cache:put(Cache, "key4", "hello"),
    {ok, "hello"} = term_cache:get(Cache, "key4"),
    not_found = term_cache:get(Cache, key1),