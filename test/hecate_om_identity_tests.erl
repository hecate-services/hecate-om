%%% Unit tests for hecate_om_identity's keypair resolution
%%% (hecate_om_identity:keypair_from/1) -- self-healing generate-on-
%%% missing behavior. Confirmed live: without this, a service whose
%%% job is a direct-dial RPC/Streaming provider (hecate-tube) silently
%%% never advertises anything -- keypair/0 stays {error, no_keypair}
%%% forever, unless something out-of-band provisions the file first.
-module(hecate_om_identity_tests).
-include_lib("eunit/include/eunit.hrl").

tmp_path() ->
    Name = binary:encode_hex(crypto:strong_rand_bytes(8)),
    filename:join("/tmp", <<"hecate_om_identity_test_", Name/binary, ".key">>).

unconfigured_path_stays_ephemeral_test() ->
    ?assertEqual(undefined, hecate_om_identity:keypair_from(undefined)).

first_boot_generates_and_persists_a_keypair_test() ->
    Path = tmp_path(),
    ?assertEqual(false, filelib:is_regular(Path)),

    KeyPair = hecate_om_identity:keypair_from({ok, Path}),

    ?assertMatch(#{public := _, private := _}, KeyPair),
    #{public := Pub, private := Priv} = KeyPair,
    ?assertEqual(32, byte_size(Pub)),
    ?assertEqual(32, byte_size(Priv)),
    ?assert(filelib:is_regular(Path)),
    %% and it's genuinely loadable back via the same path macula_identity
    %% itself would use -- not just "a file exists".
    ?assertEqual({ok, KeyPair}, macula_identity:load(Path)),
    %% Regression: a non-puzzle-hardened identity's handshake gets
    %% closed with puzzle_invalid by every station in this fleet,
    %% forever -- confirmed live, see generate_and_save/1's own comment.
    ?assert(macula_identity:puzzle_valid(macula_identity:public(KeyPair))),
    file:delete(Path).

existing_keypair_is_loaded_not_regenerated_test() ->
    Path = tmp_path(),
    Original = macula_identity:generate(),
    ok = macula_identity:save(Path, Original),

    Loaded = hecate_om_identity:keypair_from({ok, Path}),

    ?assertEqual(Original, Loaded),
    file:delete(Path).

corrupt_keypair_file_self_heals_test() ->
    Path = tmp_path(),
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, <<"not a real key file">>),

    KeyPair = hecate_om_identity:keypair_from({ok, Path}),

    ?assertMatch(#{public := _, private := _}, KeyPair),
    ?assertEqual({ok, KeyPair}, macula_identity:load(Path)),
    ?assert(macula_identity:puzzle_valid(macula_identity:public(KeyPair))),
    file:delete(Path).
