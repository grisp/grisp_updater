-module(grisp_updater_dummy).

-behaviour(grisp_updater_system).


%--- Includes ------------------------------------------------------------------

-include_lib("kernel/include/logger.hrl").

-include("grisp_updater.hrl").


%--- Exports -------------------------------------------------------------------

% Behaviour grisp_updater_source callbacks
-export([system_init/1]).
-export([system_get_global_target/1]).
-export([system_get_active/1]).
-export([system_prepare_update/2]).
-export([system_prepare_target/4]).
-export([system_set_updated/2]).
-export([system_validate/1]).
-export([system_terminate/2]).


%--- Records -------------------------------------------------------------------

-record(state, {
    device :: binary()
}).


%--- Macros --------------------------------------------------------------------

-define(DEFAULT_DEVICE, <<"dummy.img">>).
-define(DEFAULT_DEVICE_SIZE, ((4 + 256 + 256) * (1024 * 1024))).


%--- Behaviour grisp_updater_source Callback -----------------------------------

system_init(Opts) ->
    ?LOG_INFO("Initializing GRiSP updater's dummy system interface", []),
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
    ok = filelib:ensure_dir(DeviceFile),
    case file:open(DeviceFile, [raw, write, read]) of
        {error, _Reason} = Error -> Error;
        {ok, File} ->
            case file:pread(File, DeviceSize - 1, 1) of
                {ok, [_]} ->
                    ok = file:close(File),
                    {ok, #state{device = DeviceFile}};
                eof ->
                    ok = file:pwrite(File, DeviceSize - 1, <<0>>),
                    ok = file:close(File),
                    {ok, #state{device = DeviceFile}};
                {error, _Reason} = Error -> Error
        end
    end.

system_get_global_target(#state{device = Device}) ->
    #target{device = Device, offset = 0, size = undefined}.

system_get_active(_State) ->
    {0, true}.

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

system_validate(State) ->
    ?LOG_DEBUG("Current system marked as validated", []),
    {ok, State}.

system_terminate(_State, _Reason) ->
    ?LOG_INFO("Terminating dummy update system interface", []),
    ok.
