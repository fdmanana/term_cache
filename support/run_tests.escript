#!/usr/bin/env escript
%% -*- erlang -*-

main([EbinDir]) ->
    code:add_path(EbinDir),
    Modules = [list_to_atom(filename:basename(M, ".beam")) ||
        M <- filelib:wildcard(filename:join([EbinDir, "*_tests.beam"]))],
    lists:foreach(fun(M) -> eunit:test(M, [verbose]) end, Modules);

main(_) ->
    io:format("usage: run_tests.escript EBIN_DIR~n"),
    halt(1).
