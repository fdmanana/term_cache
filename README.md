# term_cache

This is a simple cache for Erlang implemented as an OTP gen_server.
Keys and values can be any Erlang term.

NOTE: it's more efficient for binary values.

There are 4 implementations of term_cache:

1. term_cache_ets: keys and values are stored in ets tables (one ordered set ets table plus on set ets table);

2. term_cache_trees: keys and values are stored in trees (Erlang module gb_trees, 1 tree for keys, 1 tree for values);

3. term_cache_pdict: keys are stored in a tree and values are stored in the process dictionary;

4. term_cache_dict: keys are stored in a tree and values in a dictionary (Erlang dict module).

* *a key is*: the user specified key plus the insertion or last access timestamp for that key/value pair
* *a value is*: user specified value, value's size, access timestamp, and a timer (if the TTL option is given)

Generally term_cache_dict offers the best performance for large datasets.
Some performance tests will be added in a near future.


Each cache instance can be configured with the following parameters:

* {name, atom()} - name of the cache process. Optional, default to none (unnamed process).
* {size, int() | string() | binary() | atom()} - maximum cache size in bytes. Defaults to the string "128Kb". Example values: 65536, "64Kb", '4Mb'.
* {policy, lru | mru} - cache entry replacement policy. Default is 'lru'.
* {ttl, int()} - the Time To Live (TTL) for cache entries. If an entry is not accessed within this time period, it will be purged from the cache. Default is 0 (no TTL).

## Compile

$ make

## Test

$ make test
