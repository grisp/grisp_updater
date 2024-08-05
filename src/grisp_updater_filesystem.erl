-module(grisp_updater_filesystem).

-behaviour(grisp_updater_storage).


%--- Includes ------------------------------------------------------------------

-include_lib("kernel/include/logger.hrl").
-include_lib("kernel/include/file.hrl").

-include("grisp_updater.hrl").


%--- Exports -------------------------------------------------------------------

% Behaviour grisp_updater_storage callbacks
-export([storage_init/1]).
-export([storage_prepare/3]).
-export([storage_open/2]).
-export([storage_write/4]).
-export([storage_read/4]).
-export([storage_close/2]).
-export([storage_terminate/2]).


%--- Behaviour grisp_updater_storage Callbacks ---------------------------------

storage_init(_Opts) ->
    ?LOG_INFO("Initializing GRiSP updater's filesystem storage", []),
    {ok, undefined}.

storage_prepare(State, #target{device = Device} = Target, ObjSize)
  when is_binary(Device) ->
    case file:read_file_info(Device) of
        {ok, #file_info{type = device, access = read_write}} -> {ok, State};
        {ok, #file_info{type = device}} -> {error, device_access_error};
        {ok, #file_info{type = regular, access = read_write}} ->
            case truncate_file(Device, file_size(Target, ObjSize)) of
                {error, _Reason} = Error -> Error;
                ok -> {ok, State}
            end;
        {ok, #file_info{type = regular}} -> {error, device_access_error};
        {ok, #file_info{}} -> {error, bad_device};
        {error, enoent} ->
            % Assume that if it doesn't exists it is a regular file
            case truncate_file(Device, file_size(Target, ObjSize)) of
                {error, _Reason} = Error -> Error;
                ok -> {ok, State}
            end
    end.

storage_open(State, Device) when is_binary(Device) ->
    case file:open(Device, [raw, read, write, binary, sync]) of
        {ok, File} -> {ok, File, State};
        {error, _Reason} = Error -> Error
    end;
storage_open(_State, Device) ->
    {error, {invalid_device, Device}}.

storage_write(State, Descriptor, Offset, Data) ->
    case file:pwrite(Descriptor, Offset, Data) of
        ok -> {ok, State};
        {error, _Reason} = Error -> Error
    end.

storage_read(State, Descriptor, Offset, Size) ->
    case file:pread(Descriptor, Offset, Size) of
        eof -> {ok, <<>>, State};
        {ok, Data} -> {ok, Data, State};
        {error, _Reason} = Error -> Error
    end.

storage_close(State, Descriptor) ->
    ok = file:close(Descriptor),
    {ok, State}.

storage_terminate(_State, _Reason) ->
    ?LOG_INFO("Terminating filesystem update storage", []),
    ok.


%--- Internal Functions --------------------------------------------------------

file_size(#target{offset = Offset, size = undefined, total = undefined}, ObjSize) ->
    Offset + ObjSize;
file_size(#target{offset = Offset, size = Size, total = undefined}, _ObjSize) ->
    Offset + Size;
file_size(#target{total = Total}, _ObjSize) ->
    Total.

truncate_file(Filename, Size) ->
    case file:open(Filename, [raw, read, write, binary, sync]) of
        {error, _Reason} = Error -> Error;
        {ok, F} ->
            try file:position(F, {bof, Size}) of
                {error, _Reason} = Error -> Error;
                {ok, _} ->
                    file:truncate(F),
                    ok
            after
                file:close(F)
            end
    end.
