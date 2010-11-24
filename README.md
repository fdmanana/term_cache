# term_cache

This is a simple cache for Erlang implemented as an OTP gen_server.
Keys and values can be any Erlang term.

NOTE: it's more efficient for binary values.

Each cache instance can be configured with the following parameters:

* {name, atom()} - name of the cache process. Optional, default to none (unnamed process).
* {size, int() | string() | binary() | atom()} - maximum cache size in bytes. Defaults to the string "128Kb". Example values: 65536, "64Kb", '4Mb'.
* {policy, lru | mru} - cache entry replacement policy. Default is 'lru'.
* {ttl, int()} - the Time To Live (TTL) for cache entries. If an entry is not accessed within this time period, it will be purged from the cache. Default is 0 (no TTL).

## Compile

$ make

## Test

$ make test
