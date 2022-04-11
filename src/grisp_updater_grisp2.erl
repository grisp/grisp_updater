-module(grisp_updater_grisp2).

-behaviour(grisp_updater_system).


%--- Includes ------------------------------------------------------------------

-include_lib("kernel/include/logger.hrl").


%--- Exports -------------------------------------------------------------------

% Behaviour grisp_updater_source callbacks
-export([system_init/1]).
-export([system_device/1]).
-export([system_get_active/1]).
-export([system_prepare_update/2]).
-export([system_set_updated/2]).
-export([system_validate/1]).
-export([system_terminate/2]).


%--- Records -------------------------------------------------------------------

-record(state, {
    current :: grisp_updater_system:system_id() | removable,
    active :: non_neg_integer(),
    update :: non_neg_integer()
}).

%--- Behaviour grisp_updater_source Callback -----------------------------------

system_init(_Opts) ->
    ?LOG_INFO("Initializing GRiSP2 update system interface", []),
    % TODO: Uses current working directory to fugre out the current
    % booted system, should be changed to use the device tree.
    #{bootstate := #{active_system := Active, update_system := Update}} =
        grisp_barebox:get_all(),
    Current = case file:get_cwd() of
        {ok, "/media/mmcsd-0-0"} -> 0;
        {ok, "/media/mmcsd-0-1"} -> 1;
        {ok, "/media/mmcsd-1-" ++ _} -> removable
    end,
    {ok, #state{current = Current, active = Active, update = Update}}.

system_device(_State) ->
    <<"/dev/mmcsd-0">>.

system_get_active(#state{current = Curr, active = Act}) ->
    {Curr, Curr =:= Act}.

system_prepare_update(#state{current = 0} = State, 1) ->
    grisp_rtems:unmount(<<"/media/mmcsd-0-1">>),
    {ok, State};
system_prepare_update(#state{current = 1} = State, 0) ->
    grisp_rtems:unmount(<<"/media/mmcsd-0-0">>),
    {ok, State};
system_prepare_update(#state{current = SysId}, SysId) ->
    {error, cannot_update_running_system};
system_prepare_update(_State, SysId) ->
    {error, {invalid_update_system, SysId}}.

system_set_updated(#state{current = 0} = State, 1) ->
    grisp_barebox:set([bootstate, update_system], 1),
    grisp_barebox:set([bootstate, update_boot_count], 1),
    grisp_barebox:commit(),
    {ok, State};
system_set_updated(#state{current = 1} = State, 0) ->
    grisp_barebox:set([bootstate, update_system], 0),
    grisp_barebox:set([bootstate, update_boot_count], 1),
    grisp_barebox:commit(),
    {ok, State}.

system_validate(#state{current = SysId, active = SysId} = State) ->
    {ok, State};
system_validate(#state{current = SysId, update = SysId} = State) ->
    grisp_barebox:set([bootstate, active_system], SysId),
    grisp_barebox:set([bootstate, update_boot_count], 0),
    grisp_barebox:commit(),
    {ok, State#state{active = SysId}};
system_validate(#state{current = removable}) ->
    {error, current_system_removable}.

system_terminate(_State, _Reason) ->
    ?LOG_INFO("Terminating GRiSP update system interface", []),
    ok.
