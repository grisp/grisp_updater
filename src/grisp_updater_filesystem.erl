-module(grisp_updater_filesystem).

-behaviour(grisp_updater_storage).


%--- Includes ------------------------------------------------------------------

-include_lib("kernel/include/logger.hrl").


%--- Exports -------------------------------------------------------------------

% Behaviour grisp_updater_storage callbacks
-export([storage_init/1]).
-export([storage_open/2]).
-export([storage_write/4]).
-export([storage_read/4]).
-export([storage_close/2]).
-export([storage_terminate/2]).


%--- Behaviour grisp_updater_storage Callbacks ---------------------------------

storage_init(_Opts) ->
    ?LOG_INFO("Initializing filesystem update storage", []),
    {ok, undefined}.

storage_open(State, Device) when is_binary(Device) ->
    case file:open(Device, [raw, read, write, binary]) of
        {ok, File} -> {ok, File, State};
        {error, _Reason} = Error -> Error
    end;
storage_open(_State, Device) ->
    {error, {invalid_device, Device}}.

storage_write(State, Descriptor, Offset, Data) ->
    ?LOG_DEBUG("Writing ~b bytes at ~b", [iolist_size(Data), Offset]),
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
