-module(grisp_updater_tarball).

-behaviour(grisp_updater_source).


%--- Includes ------------------------------------------------------------------

-include_lib("kernel/include/logger.hrl").


%--- Exports -------------------------------------------------------------------

% Behaviour grisp_updater_source callbacks
-export([source_init/1]).
-export([source_open/3]).
-export([source_stream/4]).
-export([source_cancel/3]).
-export([source_close/2]).
-export([source_terminate/2]).


%--- Records -------------------------------------------------------------------

-record(state, {
    files = #{} :: #{reference() => binary()}
}).


%--- Behaviour grisp_updater_source Callbacks ----------------------------------

source_init(_Opts) ->
    ?LOG_INFO("Initializing GRiSP updater's tarball source", []),
    {ok, #state{}}.

source_open(#state{files = Files} = State, Url, _Opts) ->
    case uri_string:parse(Url) of
        #{scheme := <<"tarball">>, host := <<>>, path := Path} ->
            case filelib:is_regular(Path) of
                false ->
                    {error, {tarball_not_found, Path}};
                true ->
                    SourceRef = make_ref(),
                    {ok, SourceRef, State#state{
                        files = Files#{SourceRef => Path}
                    }}
            end;
        _Other ->
            not_supported
    end.

source_stream(#state{files = Files} = State, SourceRef, Path, _Opts) ->
    case maps:find(SourceRef, Files) of
        error -> {error, unknown_source};
        {ok, Url} ->
            Filename = tarball_path(Path),
            case erl_tar:extract(Url, [memory, {files, [Filename]}]) of
                {ok,[{Filename, Data}]} -> {data, Data, State};
                {error, {_, enoent}} -> {error, {tarball_not_found, Url}};
                {error, _Reason} = Error -> Error
            end
    end.

source_cancel(State, _SourceRef, _StreamRef) ->
    State.

source_close(#state{files = Files} = State, SourceRef) ->
    State#state{files = maps:remove(SourceRef, Files)}.

source_terminate(_State, _Reason) ->
    ?LOG_INFO("Terminating tarball update source", []),
    ok.


%--- Internal Function ---------------------------------------------------------

tarball_path(Path) when is_list(Path) -> Path;
tarball_path(Path) when is_binary(Path) -> unicode:characters_to_list(Path).
