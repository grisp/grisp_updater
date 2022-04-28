-module(grisp_updater_sup).

-behaviour(supervisor).


%--- Exports -------------------------------------------------------------------

% API functions
-export([start_link/0]).

% Bheaviour supervisor callbacks
-export([init/1]).


%--- API Functions -------------------------------------------------------------

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).


%--- Behaviour superbisor Callbacks --------------------------------------------

init([]) ->
    SystemOpts = case application:get_env(grisp_updater, system) of
        undefined -> {grisp_updater_dummy, #{}};
        {ok, {M1, A1} = V1} when is_atom(M1), is_map(A1) -> V1
    end,
    StorageOpts = case application:get_env(grisp_updater, storage) of
        undefined -> {grisp_updater_filesystem, #{}};
        {ok, {M2, A2} = V2} when is_atom(M2), is_map(A2) -> V2
    end,
    SourceOpts = case application:get_env(grisp_updater, sources) of
        undefined -> [{grisp_updater_tarball, #{}}];
        {ok, V3} when is_list(V3) -> V3
    end,
    LoaderOpts = case application:get_env(grisp_updater, loader) of
        undefined -> #{};
        {ok, V4} when is_map(V4) -> V4
    end,
    CheckerOpts = case application:get_env(grisp_updater, checker) of
        undefined -> #{};
        {ok, V5} when is_map(V5) -> V5
    end,
    {ok, {#{
            strategy => one_for_all
        }, [
            #{id => grisp_updater_source,
              start => {grisp_updater_source, start_link, [#{
                            backends => SourceOpts
              }]}},
            #{id => grisp_updater_storage,
              start => {grisp_updater_storage, start_link, [#{
                            backend => StorageOpts
              }]}},
            #{id => grisp_updater_checker,
              start => {grisp_updater_checker, start_link, [CheckerOpts]}},
            #{id => grisp_updater_loader,
              start => {grisp_updater_loader, start_link, [LoaderOpts]}},
            #{id => grisp_updater_manager,
              start => {grisp_updater_manager, start_link, [#{
                            system => SystemOpts
              }]}}
        ]}
    }.


%--- Internal Functions --------------------------------------------------------
