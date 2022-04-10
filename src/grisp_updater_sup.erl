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
    SourceOpts = case application:get_env(grisp_updater, source) of
        undefined -> {grisp_updater_tarball, #{}};
        {ok, {M3, A3} = V3} when is_atom(M3), is_map(A3) -> V3
    end,
    {ok, {#{
            strategy => one_for_all
        }, [
            #{id => grisp_updater_source,
              start => {grisp_updater_source, start_link, [#{
                            backend => SourceOpts
              }]}},
            #{id => grisp_updater_storage,
              start => {grisp_updater_storage, start_link, [#{
                            backend => StorageOpts
              }]}},
            #{id => grisp_updater_checker,
              start => {grisp_updater_checker, start_link, [#{
              }]}},
            #{id => grisp_updater_loader,
              start => {grisp_updater_loader, start_link, [#{
              }]}},
            #{id => grisp_updater_manager,
              start => {grisp_updater_manager, start_link, [#{
                            system => SystemOpts
              }]}}
        ]}
    }.


%--- Internal Functions --------------------------------------------------------
