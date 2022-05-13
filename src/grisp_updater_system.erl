-module(grisp_updater_system).

%--- Includes ------------------------------------------------------------------

-include("grisp_updater.hrl").


%--- Types ---------------------------------------------------------------------

-type system_id() :: non_neg_integer().
-type system_state() :: trial | validated.

-export_type([system_id/0, system_state/0]).


%--- Behaviour Definition ------------------------------------------------------

-callback system_init(Opts :: map()) ->
    {ok, State :: term()} | {error, term()}.
-callback system_get_global_target(State :: term()) ->
    GlobalTarget :: target().
-callback system_get_active(State :: term()) ->
    {SysId :: system_id() | removable, Validated :: boolean() | undefined}.
-callback system_get_updatable(State :: term()) ->
    {ok, SysId :: system_id(), SystemTarget :: target()} | {error, Reason :: term}.
-callback system_prepare_update(State :: term(), SysId :: system_id()) ->
    {ok, State :: term()} | {error, term()}.
-callback system_prepare_target(State :: term(), SysId :: system_id(),
                                SysTarget :: target(), Spec :: target_spec()) ->
    {ok, Target :: target()}.
-callback system_set_updated(State :: term(), SysId :: system_id()) ->
    {ok, State :: term()} | {error, term()}.
-callback system_validate(State :: term()) ->
    {ok, State :: term()} | {error, term()}.
-callback system_object_updated(State :: term(), Object :: #object{},
                                Target :: #target{}) ->
    {ok, State :: term()} | {error, term()}.
-callback system_updated(State :: term()) ->
    {ok, State :: term()} | {error, term()}.
-callback system_terminate(State :: term(), Reason :: term()) ->
    ok.

-optional_callbacks([system_get_updatable/1, system_prepare_target/4,
                     system_object_updated/3, system_updated/1]).
