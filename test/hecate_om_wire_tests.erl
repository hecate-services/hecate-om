%%% Unit tests for hecate_om_wire:field/2,3 and retryable/1 — pure
%%% logic, no mesh involved, same convention as hecate_om_capabilities.
%%% erl/hecate_om_pubsub.erl's own exported pure helpers
%%% (PLAN_HECATE_OM_MESH_WRAPPERS.md, pieces F and G).
-module(hecate_om_wire_tests).
-include_lib("eunit/include/eunit.hrl").

atom_key_found_directly_test() ->
    ?assertEqual(<<"pong">>, hecate_om_wire:field(ping, #{ping => <<"pong">>})).

atom_key_falls_back_to_binary_form_test() ->
    ?assertEqual(<<"pong">>, hecate_om_wire:field(ping, #{<<"ping">> => <<"pong">>})).

binary_key_falls_back_to_existing_atom_form_test() ->
    %% `ping' is guaranteed to already exist as an atom -- it's a
    %% literal a few lines above in this very module.
    ?assertEqual(<<"pong">>, hecate_om_wire:field(<<"ping">>, #{ping => <<"pong">>})).

binary_key_found_directly_test() ->
    ?assertEqual(<<"pong">>, hecate_om_wire:field(<<"ping">>, #{<<"ping">> => <<"pong">>})).

atom_form_wins_when_both_present_test() ->
    Payload = #{ping => atom_form, <<"ping">> => binary_form},
    ?assertEqual(atom_form, hecate_om_wire:field(ping, Payload)),
    ?assertEqual(atom_form, hecate_om_wire:field(<<"ping">>, Payload)).

missing_key_returns_undefined_by_default_test() ->
    ?assertEqual(undefined, hecate_om_wire:field(missing, #{})),
    ?assertEqual(undefined, hecate_om_wire:field(<<"missing">>, #{})).

missing_key_returns_explicit_default_test() ->
    ?assertEqual(none, hecate_om_wire:field(missing, #{}, none)),
    ?assertEqual(none, hecate_om_wire:field(<<"missing">>, #{}, none)).

%% A present-but-falsy value must be returned as-is, not treated as a
%% miss -- the whole point of using maps:find under the hood rather
%% than a maps:get/2-with-undefined-default that can't tell "absent"
%% from "present and undefined".
present_but_falsy_value_is_not_mistaken_for_absent_test() ->
    ?assertEqual(false, hecate_om_wire:field(flag, #{flag => false})),
    ?assertEqual(0, hecate_om_wire:field(count, #{count => 0}, unset)).

%% A binary key with no atom form anywhere in the VM must not crash the
%% caller's handler over a decode-convenience lookup -- this is the
%% behavior binary_to_existing_atom/2 alone does not give you.
binary_key_with_no_existing_atom_form_does_not_raise_test() ->
    NoAtomForm = <<"hecate_om_wire_tests_definitely_never_an_atom_anywhere_zzz">>,
    ?assertEqual(undefined, hecate_om_wire:field(NoAtomForm, #{})),
    Payload = #{NoAtomForm => <<"still findable via the binary form">>},
    ?assertEqual(<<"still findable via the binary form">>,
                 hecate_om_wire:field(NoAtomForm, Payload)).

%%% retryable/1 (piece G) -- real BOLT#4 codes from macula_bolt4:table/0,
%%% not fabricated ones, so a real table edit is what would break these.

retryable_is_false_on_success_test() ->
    ?assertEqual(false, hecate_om_wire:retryable({ok, #{}})).

%% 16#02 temporary_relay_failure, retry => same_path_after_backoff.
retryable_true_for_a_backoff_coded_failure_test() ->
    ?assertEqual(true, hecate_om_wire:retryable(
                          {error, {call_error, 16#02, temporary_relay_failure}})).

%% 16#05 target_realm_refused, retry => application (handler-level
%% remedy, not a transport retry).
retryable_false_for_an_application_coded_failure_test() ->
    ?assertEqual(false, hecate_om_wire:retryable(
                           {error, {call_error, 16#05, target_realm_refused}})).

%% 16#0A crypto_puzzle_invalid, retry => crypto_drop -- security-
%% critical, must never be retried automatically.
retryable_false_for_a_crypto_drop_coded_failure_test() ->
    ?assertEqual(false, hecate_om_wire:retryable(
                           {error, {call_error, 16#0A, crypto_puzzle_invalid}})).

%% macula_bolt4:is_retryable/1 raises for a code its own table doesn't
%% recognize (a real possibility across a protocol version skew, not a
%% fabricated edge case) -- must resolve to retryable, not crash the
%% caller over a code this build doesn't know yet.
retryable_true_for_an_unrecognized_bolt4_code_test() ->
    ?assertEqual(true, hecate_om_wire:retryable(
                          {error, {call_error, 16#FE, some_future_code}})).

%% An error macula didn't code-classify at all (a raw catch, a
%% timeout) -- nothing for the BOLT#4 table to say, decided directly.
retryable_true_for_an_unclassified_error_test() ->
    ?assertEqual(true, hecate_om_wire:retryable({error, timeout})),
    ?assertEqual(true, hecate_om_wire:retryable({'EXIT', some_reason})).
