-module(grisp_updater_tools).


%--- Exports -------------------------------------------------------------------

% API Functions
-export([resolve_path/1]).
-export([resolve_file_list/2]).
-export([config_file_list/3]).
-export([config_certificates/3]).


%--- API Functions -------------------------------------------------------------

resolve_path(Path) when is_binary(Path) ->
    {ok, Path};
resolve_path(Path) when is_list(Path) ->
    {ok, iolist_to_binary(Path)};
resolve_path({priv, AppName, RelPath}) ->
    case code:priv_dir(AppName) of
        {error, bad_name} ->
            {error, {priv_not_found, AppName}};
        BaseDir ->
            {ok, filename:join(BaseDir, iolist_to_binary(RelPath))}
    end.

resolve_file_list(Path, Pattern) when is_list(Pattern) ->
    case resolve_path(Path) of
        {error, _Reason} = Error -> Error;
        {ok, PathBin} ->
            PathStr = binary_to_list(PathBin),
            case {filelib:is_regular(PathStr), filelib:is_dir(PathStr)} of
                {true, false} ->
                    {ok, [PathBin]};
                {false, true} ->
                    {ok, [list_to_binary(filename:join(PathStr, F))
                     || F <- filelib:wildcard(Pattern, PathStr)]};
                _ ->
                    {error, {invalid_file_or_directory, PathBin}}
            end
    end.

config_file_list(AppName, ConfKey, Pattern) ->
    Specs  = case application:get_env(AppName, ConfKey) of
        {ok, Items} when is_list(Items) -> Items;
        {ok, Item} -> [Item];
        undefined -> []
    end,
    multi_resolve_file_list(Specs, Pattern, [], []).

config_certificates(AppName, ConfKey, Pattern) ->
    {Filenames, Errors1} = config_file_list(AppName, ConfKey, Pattern),
    {Certs, Errors2} = multi_load_certificate(Filenames, [], []),
    {Certs, Errors1 ++ Errors2}.


%--- Internal Functions --------------------------------------------------------

multi_resolve_file_list([], _Ptrn, Results, Errors) ->
    {lists:append(lists:reverse(Results)), lists:reverse(Errors)};
multi_resolve_file_list([Spec | Rest], Ptrn, Results, Errors) ->
    case resolve_file_list(Spec, Ptrn) of
        {error, Reason} ->
            multi_resolve_file_list(Rest, Ptrn, Results, [Reason | Errors]);
        {ok, Filenames} ->
            multi_resolve_file_list(Rest, Ptrn, [Filenames | Results], Errors)
    end.

multi_load_certificate([], Results, Errors) ->
    {lists:append(lists:reverse(Results)), lists:reverse(Errors)};
multi_load_certificate([Filename | Rest], Results, Errors) ->
    try termseal:load_certificates(Filename) of
        Certificates ->
            multi_load_certificate(Rest, [Certificates | Results], Errors)
    catch
        Reason ->
            multi_load_certificate(Rest, Results, [Reason | Errors])
    end.
