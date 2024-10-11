-module(grisp_updater_dummy).

-behaviour(grisp_updater_system).


%--- Includes ------------------------------------------------------------------

-include_lib("kernel/include/logger.hrl").

-include("grisp_updater.hrl").


%--- Exports -------------------------------------------------------------------

% Behaviour grisp_updater_system callbacks
-export([system_init/1]).
-export([system_get_global_target/1]).
-export([system_get_systems/1]).
-export([system_prepare_update/2]).
-export([system_prepare_target/4]).
-export([system_set_updated/2]).
-export([system_cancel_update/1]).
-export([system_validate/1]).
-export([system_terminate/2]).


%--- Records -------------------------------------------------------------------

-record(state, {
    boot :: grisp_updater_system:system_id() | removable,
    valid :: grisp_updater_system:system_id(),
    next :: grisp_updater_system:system_id(),
    device :: binary(),
    size :: non_neg_integer()
}).


%--- Macros --------------------------------------------------------------------

-define(DEFAULT_BOOT, removable).
-define(DEFAULT_VALID, 0).
-define(DEFAULT_NEXT, 0).
-define(DEFAULT_DEVICE, <<"dummy.img">>).
-define(DEFAULT_DEVICE_SIZE, ((4 + 256 + 256) * (1024 * 1024))).


%--- Behaviour grisp_updater_system Callback -----------------------------------

system_init(Opts) ->
    ?LOG_INFO("Initializing GRiSP updater's dummy system interface", []),
    Boot = case maps:find(boot_system, Opts) of
        {ok, Sys1} when Sys1 =:= removable; Sys1 >= 0, Sys1 =< 1 -> Sys1;
        error -> ?DEFAULT_BOOT
    end,
    Valid = case maps:find(valid_system, Opts) of
        {ok, Sys2} when Sys2 >= 0, Sys2 =< 1 -> Sys2;
        error -> ?DEFAULT_VALID
    end,
    Next = case maps:find(next_system, Opts) of
        {ok, Sys3} when Sys3 >= 0, Sys3 =< 1 -> Sys3;
        error -> ?DEFAULT_NEXT
    end,
    DeviceFile = case maps:find(device_file, Opts) of
        {ok, F} when is_list(F); is_binary(F) -> F;
        error ->
            {ok, CurrDir} = file:get_cwd(),
            filename:join(CurrDir, ?DEFAULT_DEVICE)
    end,
    DeviceSize = case maps:find(device_size, Opts) of
        {ok, S} when is_integer(S), S > 0 -> S;
        error -> ?DEFAULT_DEVICE_SIZE
    end,
    State = #state{boot = Boot, valid = Valid, next = Next,
                   device = DeviceFile, size = DeviceSize},
    ok = filelib:ensure_dir(DeviceFile),
    case file:open(DeviceFile, [raw, write, read]) of
        {error, _Reason} = Error -> Error;
        {ok, File} ->
            case file:pread(File, DeviceSize - 1, 1) of
                {ok, [_]} ->
                    ok = file:close(File),
                    {ok, State};
                eof ->
                    ok = file:pwrite(File, DeviceSize - 1, <<0>>),
                    ok = file:close(File),
                    {ok, State};
                {error, _Reason} = Error -> Error
        end
    end.

system_get_global_target(#state{device = Device, size = Size}) ->
    #target{device = Device, offset = 0, size = Size, total = Size}.

system_get_systems(#state{boot = Boot, valid = Valid, next = Next}) ->
    {Boot, Valid, Next}.

system_prepare_update(State, 1) ->
    ?LOG_DEBUG("Preparing system 1 for update", []),
    {ok, State}.

system_prepare_target(_State, SysId, _SysTarget,
                      #file_target_spec{context = Context, path = Path}) ->
    Path2 = iolist_to_binary(lists:join("#", string:split(Path, "/", all))),
    Path3 = iolist_to_binary(io_lib:format("dummy.~s", [Path2])),
    Path4 = case Context of
        system -> iolist_to_binary(io_lib:format("~s.~b", [Path3, SysId]));
        _ -> Path3
    end,
    {ok, #target{device = Path4, offset = 0, size = undefined}};
system_prepare_target(_State, _SysId, #target{offset = SysOffset} = SysTarget,
                      #raw_target_spec{context = system, offset = ObjOffset}) ->
    {ok, SysTarget#target{offset = SysOffset + ObjOffset}};
system_prepare_target(#state{device = Device}, _SysId, _SysTarget,
                      #raw_target_spec{context = global, offset = Offset}) ->
    {ok, #target{device = Device, offset = Offset, size = undefined}}.

system_set_updated(State, SystemId) ->
    ?LOG_DEBUG("System ~b marked as update", [SystemId]),
    {ok, State}.

system_cancel_update(State) ->
    ?LOG_DEBUG("Update canceled", []),
    {ok, State}.

system_validate(State) ->
    ?LOG_DEBUG("Current system marked as validated", []),
    {ok, State}.

system_terminate(_State, _Reason) ->
    ?LOG_INFO("Terminating GRiSP updater's dummy system interface", []),
    ok.
